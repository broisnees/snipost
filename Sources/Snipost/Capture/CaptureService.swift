import AppKit
import ScreenCaptureKit

enum CaptureKind: String, CaseIterable {
    case area
    case window
    case screen
}

/// ScreenCaptureKit backend: the app captures directly (no `screencapture`
/// child process), so Screen Recording permission is checked against Snipost
/// itself and failures surface as a real error we can explain to the user.
enum CaptureService {
    static func capture(_ kind: CaptureKind, completion: @escaping @MainActor (CGImage?) -> Void) {
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let target = targetDisplay(in: content) else {
                    completion(nil)
                    return
                }

                let includeCursor = Preferences.shared.includeCursor

                switch kind {
                case .screen:
                    try await Task.sleep(nanoseconds: 250_000_000) // let the menu close
                    completion(try await captureDisplay(target.display, showsCursor: includeCursor))

                case .area:
                    // Prefer a frame the hotkey tap froze before dismissing an
                    // open menu — that's how menus end up in the snip.
                    let frozen: CGImage
                    if let pending = PendingFrozenFrame.consume(displayID: target.display.displayID) {
                        frozen = pending
                    } else {
                        // Let our own menu finish closing before freezing.
                        try await Task.sleep(nanoseconds: 200_000_000)
                        frozen = try await captureDisplay(target.display, showsCursor: includeCursor)
                    }
                    let viewSize = target.screen.frame.size
                    // Windows too, so Space can flip to window capture.
                    SelectionOverlayController.begin(
                        mode: .area,
                        screen: target.screen,
                        frozen: frozen,
                        windows: pickableWindows(in: content, display: target.display)
                    ) { result in
                        switch result {
                        case .rect(let viewRect):
                            completion(crop(frozen, viewRect: viewRect, viewSize: viewSize))
                        case .window(let scWindow, let viewRect):
                            finishWindow(scWindow, viewRect: viewRect, frozen: frozen, viewSize: viewSize, completion: completion)
                        case .cancelled:
                            completion(nil)
                        }
                    }

                case .window:
                    try await Task.sleep(nanoseconds: 200_000_000)
                    let frozen = try await captureDisplay(target.display, showsCursor: includeCursor)
                    let viewSize = target.screen.frame.size
                    let pickable = pickableWindows(in: content, display: target.display)
                    SelectionOverlayController.begin(
                        mode: .window,
                        screen: target.screen,
                        frozen: frozen,
                        windows: pickable
                    ) { result in
                        if case .window(let scWindow, let viewRect) = result {
                            finishWindow(scWindow, viewRect: viewRect, frozen: frozen, viewSize: viewSize, completion: completion)
                        } else {
                            completion(nil)
                        }
                    }
                }
            } catch {
                presentPermissionHelp()
                completion(nil)
            }
        }
    }

    @MainActor
    private static func finishWindow(
        _ scWindow: SCWindow, viewRect: CGRect, frozen: CGImage, viewSize: CGSize,
        completion: @escaping @MainActor (CGImage?) -> Void
    ) {
        Task { @MainActor in
            // Give the overlay a beat to disappear first.
            try? await Task.sleep(nanoseconds: 120_000_000)
            if let isolated = try? await captureWindow(scWindow) {
                completion(isolated)
            } else {
                // Clean capture failed — crop the window's rect out of the frozen screen.
                completion(crop(frozen, viewRect: viewRect, viewSize: viewSize))
            }
        }
    }

    /// "Repeat last area": captures the previously selected rect again with
    /// no overlay.
    static func captureLastArea(completion: @escaping @MainActor (CGImage?) -> Void) {
        Task { @MainActor in
            guard let rect = SelectionOverlayController.lastArea else {
                Toast.show("No previous area yet — make an area capture first")
                completion(nil)
                return
            }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let target = targetDisplay(in: content) else { completion(nil); return }
                let size = target.screen.frame.size
                let clamped = rect.intersection(CGRect(origin: .zero, size: size))
                guard !clamped.isEmpty else { completion(nil); return }
                let full = try await captureDisplay(target.display, showsCursor: Preferences.shared.includeCursor)
                completion(crop(full, viewRect: clamped, viewSize: size))
            } catch {
                presentPermissionHelp()
                completion(nil)
            }
        }
    }

    // MARK: Region picking (recording / AI watch)

    /// A dragged-out area of one display, in every coordinate space callers need.
    struct PickedRegion {
        let display: SCDisplay
        let screen: NSScreen
        /// Bottom-left origin, relative to the screen.
        let viewRect: CGRect

        /// Top-left origin in display points — what SCStreamConfiguration.sourceRect wants.
        var sourceRect: CGRect {
            CGRect(x: viewRect.minX, y: screen.frame.height - viewRect.maxY,
                   width: viewRect.width, height: viewRect.height)
        }

        /// Global Cocoa coordinates, for placing windows around the region.
        var globalRect: NSRect {
            viewRect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        }

        var pointPixelScale: CGFloat { screen.backingScaleFactor }
    }

    /// Freezes the display under the mouse and lets the user drag a region.
    static func pickRegion(hint: String, completion: @escaping @MainActor (PickedRegion?) -> Void) {
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let target = targetDisplay(in: content) else {
                    completion(nil)
                    return
                }
                try await Task.sleep(nanoseconds: 200_000_000)
                let frozen = try await captureDisplay(target.display, showsCursor: false)
                SelectionOverlayController.begin(
                    mode: .area,
                    screen: target.screen,
                    frozen: frozen,
                    windows: pickableWindows(in: content, display: target.display),
                    hint: hint
                ) { result in
                    switch result {
                    case .rect(let rect), .window(_, let rect):
                        let bounds = CGRect(origin: .zero, size: target.screen.frame.size)
                        completion(PickedRegion(display: target.display, screen: target.screen,
                                                viewRect: rect.intersection(bounds)))
                    case .cancelled:
                        completion(nil)
                    }
                }
            } catch {
                presentPermissionHelp()
                completion(nil)
            }
        }
    }

    /// Repeated snapshots of one region (scrolling capture, AI watch). Builds
    /// the content filter once — SCShareableContent is the expensive part.
    final class RegionGrabber: @unchecked Sendable {
        private let filter: SCContentFilter
        private let config: SCStreamConfiguration

        init(_ region: PickedRegion, maxPixelSize: CGFloat? = nil) async throws {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let display = content.displays.first { $0.displayID == region.display.displayID } ?? region.display
            filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            config = SCStreamConfiguration()
            var scale = region.pointPixelScale
            if let maxPixelSize {
                let longest = max(region.sourceRect.width, region.sourceRect.height) * scale
                if longest > maxPixelSize { scale *= maxPixelSize / longest }
            }
            config.sourceRect = region.sourceRect
            config.width = max(2, Int(region.sourceRect.width * scale))
            config.height = max(2, Int(region.sourceRect.height * scale))
            config.showsCursor = false
        }

        func grab() async throws -> CGImage {
            try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        }
    }

    /// Snapshot of a region with Snipost's own windows (HUDs, borders) left out.
    static func captureRegion(_ region: PickedRegion, maxPixelSize: CGFloat? = nil) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let display = content.displays.first { $0.displayID == region.display.displayID } ?? region.display
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let config = SCStreamConfiguration()
        var scale = region.pointPixelScale
        if let maxPixelSize {
            let longest = max(region.sourceRect.width, region.sourceRect.height) * scale
            if longest > maxPixelSize { scale *= maxPixelSize / longest }
        }
        config.sourceRect = region.sourceRect
        config.width = max(2, Int(region.sourceRect.width * scale))
        config.height = max(2, Int(region.sourceRect.height * scale))
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    // MARK: Display / window selection

    @MainActor
    static func targetDisplay(in content: SCShareableContent) -> (display: SCDisplay, screen: NSScreen)? {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return nil }
        let screenID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        let display = content.displays.first { $0.displayID == screenID } ?? content.displays.first
        guard let display else { return nil }
        return (display, screen)
    }

    private static func pickableWindows(in content: SCShareableContent, display: SCDisplay) -> [SCWindow] {
        let filtered = content.windows.filter { window in
            window.isOnScreen
                && window.windowLayer == 0
                && window.frame.width > 60 && window.frame.height > 40
                && window.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier
                && window.frame.intersects(display.frame)
        }
        // Hit-testing must go front-to-back; SCShareableContent gives no z-order,
        // but the CG window list does.
        let order = zOrderedWindowIDs()
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return filtered.sorted { (rank[$0.windowID] ?? Int.max) < (rank[$1.windowID] ?? Int.max) }
    }

    private static func zOrderedWindowIDs() -> [CGWindowID] {
        guard let info = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return info.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
    }

    // MARK: ScreenCaptureKit captures

    struct CaptureUnavailable: Error {}

    /// Used by the hotkey tap (off the main thread) to freeze the display —
    /// including any open menu and the live cursor — before menus get dismissed.
    static func freezeDisplayUnderMouse(showsCursor: Bool) async throws -> (image: CGImage, displayID: CGDirectDisplayID) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mouse = CGEvent(source: nil)?.location ?? .zero
        guard let display = content.displays.first(where: { $0.frame.contains(mouse) }) ?? content.displays.first else {
            throw CaptureUnavailable()
        }
        let image = try await captureDisplay(display, showsCursor: showsCursor)
        return (image, display.displayID)
    }

    static func captureDisplay(_ display: SCDisplay, showsCursor: Bool) async throws -> CGImage {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.showsCursor = showsCursor
        config.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Must outlive the SCStreamConfiguration: SCK copies the config without
    /// retaining the color, and a temporary (e.g. NSColor.clear.cgColor)
    /// dangles and crashes in CFRetain.
    private static let clearBackground = CGColor(red: 0, green: 0, blue: 0, alpha: 0)

    private static func captureWindow(_ window: SCWindow) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.showsCursor = false
        config.captureResolution = .best
        config.backgroundColor = clearBackground
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Maps a selection in overlay-view points back to pixels of the frozen capture.
    static func crop(_ image: CGImage, viewRect: CGRect, viewSize: CGSize) -> CGImage? {
        let sx = CGFloat(image.width) / viewSize.width
        let sy = CGFloat(image.height) / viewSize.height
        let pixelRect = CGRect(
            x: viewRect.minX * sx,
            y: (viewSize.height - viewRect.maxY) * sy, // CGImage rows start at the top
            width: viewRect.width * sx,
            height: viewRect.height * sy
        ).integral
        return image.cropping(to: pixelRect)
    }

    @MainActor
    static func presentPermissionHelp() {
        let alert = NSAlert()
        alert.messageText = "Snipost needs Screen Recording permission"
        alert.informativeText = """
        Enable Snipost in System Settings → Privacy & Security → \
        Screen & System Audio Recording, then quit and reopen Snipost.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    static func loadCGImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
