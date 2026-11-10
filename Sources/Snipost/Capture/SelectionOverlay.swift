import AppKit
import ScreenCaptureKit

/// Fullscreen snipping overlay: shows the frozen capture, dims it, and lets the
/// user drag an area (or click a window). Esc cancels.
@MainActor
final class SelectionOverlayController {
    enum Mode {
        case area
        case window
    }

    enum Result {
        case rect(CGRect)
        case window(SCWindow, CGRect) // window plus its rect in overlay-view points
        case cancelled
    }

    private static var current: SelectionOverlayController?

    /// Last confirmed area selection (view coordinates), persisted for
    /// "repeat last area".
    static var lastArea: CGRect? {
        get {
            guard let string = UserDefaults.standard.string(forKey: "lastAreaRect") else { return nil }
            let rect = NSRectFromString(string)
            return rect.width > 4 && rect.height > 4 ? rect : nil
        }
        set {
            UserDefaults.standard.set(newValue.map { NSStringFromRect($0) }, forKey: "lastAreaRect")
        }
    }

    private let window: OverlayWindow
    private let completion: @MainActor (Result) -> Void

    static func begin(
        mode: Mode,
        screen: NSScreen,
        frozen: CGImage,
        windows: [SCWindow],
        hint: String? = nil,
        completion: @escaping @MainActor (Result) -> Void
    ) {
        current?.finish(.cancelled)
        current = SelectionOverlayController(
            mode: mode,
            screen: screen,
            frozen: frozen,
            windows: windows,
            hint: hint,
            completion: completion
        )
    }

    private init(
        mode: Mode,
        screen: NSScreen,
        frozen: CGImage,
        windows: [SCWindow],
        hint: String?,
        completion: @escaping @MainActor (Result) -> Void
    ) {
        self.completion = completion

        let view = SelectionView(mode: mode, frozen: frozen, windows: windows, screen: screen)
        view.hint = hint
        // Non-activating panel: taking key status without activating the app
        // keeps other apps' open menus/popovers alive so they can be snipped.
        window = OverlayWindow(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.isOpaque = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.acceptsMouseMovedEvents = true
        window.contentView = view
        view.onFinish = { [weak self] result in self?.finish(result) }

        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }

    private func finish(_ result: Result) {
        window.orderOut(nil)
        Self.current = nil
        completion(result)
    }
}

/// Borderless panels refuse key status by default, which would silently
/// swallow the Esc key — opt back in so keyboard events reach the view.
private final class OverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class SelectionView: NSView {
    private(set) var mode: SelectionOverlayController.Mode
    let frozen: CGImage
    let windows: [SCWindow]
    let screenFrame: NSRect

    var onFinish: (@MainActor (SelectionOverlayController.Result) -> Void)?
    var hint: String?

    private var dragStart: NSPoint?
    private var dragCurrent: NSPoint?
    private var hoverWindow: SCWindow?
    /// A recalled/adjustable area (Return recalls the last one; arrows nudge,
    /// ⇧+arrows resize, ⌥ = 10pt steps; Return captures).
    private var pending: CGRect?

    init(mode: SelectionOverlayController.Mode, frozen: CGImage, windows: [SCWindow], screen: NSScreen) {
        self.mode = mode
        self.frozen = frozen
        self.windows = windows
        self.screenFrame = screen.frame
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let tracking = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)

        // Highlight whatever is already under the mouse — clicking without
        // moving first should still pick a window.
        if mode == .window, let window {
            updateHover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: mode == .area ? .crosshair : .pointingHand)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .high
        ctx.draw(frozen, in: bounds)

        let selection = activeRect()
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.42))
        if let selection {
            ctx.beginPath()
            ctx.addRect(bounds)
            ctx.addRect(selection)
            ctx.fillPath(using: .evenOdd)

            ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
            ctx.setLineWidth(1)
            ctx.stroke(selection.insetBy(dx: -0.5, dy: -0.5))
        } else {
            ctx.fill(bounds)
        }
        // Deliberately nothing else: no hint pill, no size badge.
    }

    private func drawSizeLabel(for selection: CGRect, in ctx: CGContext) {
        guard mode == .area else { return }
        let scale = CGFloat(frozen.width) / max(bounds.width, 1)
        let text = "\(Int(selection.width * scale)) × \(Int(selection.height * scale))"
        drawBadge(text, at: CGPoint(x: selection.midX, y: max(selection.minY - 26, 8)))
    }

    private func drawHint() {
        let text = hint ?? (mode == .area
            ? "Drag to select an area — Esc to cancel"
            : "Click a window — Esc to cancel")
        drawBadge(text, at: CGPoint(x: bounds.midX, y: bounds.maxY - 48))
    }

    private func drawBadge(_ text: String, at center: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        let padded = NSRect(
            x: center.x - size.width / 2 - 10,
            y: center.y - size.height / 2 - 5,
            width: size.width + 20,
            height: size.height + 10
        )
        let path = NSBezierPath(roundedRect: padded, xRadius: padded.height / 2, yRadius: padded.height / 2)
        NSColor.black.withAlphaComponent(0.65).setFill()
        path.fill()
        string.draw(at: NSPoint(x: padded.minX + 10, y: padded.minY + 5))
    }

    // MARK: Geometry

    private func activeRect() -> CGRect? {
        switch mode {
        case .area:
            guard let start = dragStart, let current = dragCurrent else { return pending }
            return CGRect(
                x: min(start.x, current.x),
                y: min(start.y, current.y),
                width: abs(start.x - current.x),
                height: abs(start.y - current.y)
            )
        case .window:
            guard let hoverWindow else { return nil }
            return viewRect(for: hoverWindow)
        }
    }

    /// SCWindow frames are global with a top-left origin; the view is bottom-up
    /// within its own screen.
    private func viewRect(for scWindow: SCWindow) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screenFrame.height
        let frame = scWindow.frame
        let cocoaY = primaryHeight - frame.maxY
        return CGRect(
            x: frame.minX - screenFrame.minX,
            y: cocoaY - screenFrame.minY,
            width: frame.width,
            height: frame.height
        )
    }

    // MARK: Input

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch mode {
        case .area:
            pending = nil
            dragStart = point
            dragCurrent = point
            needsDisplay = true
        case .window:
            if let hoverWindow {
                onFinish?(.window(hoverWindow, viewRect(for: hoverWindow)))
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .area else { return }
        dragCurrent = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard mode == .area, let rect = activeRect() else { return }
        dragStart = nil
        dragCurrent = nil
        if rect.width > 4, rect.height > 4 {
            finishArea(rect)
        } else {
            needsDisplay = true // ignore accidental clicks; keep selecting
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard mode == .window else { return }
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    private func updateHover(at point: NSPoint) {
        let newHover = windows.first { viewRect(for: $0).contains(point) }
        if newHover?.windowID != hoverWindow?.windowID {
            hoverWindow = newHover
            needsDisplay = true
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Esc
            onFinish?(.cancelled)
        case 49: // Space: toggle area ⇄ window, like macOS
            guard dragStart == nil, !windows.isEmpty else { return }
            mode = mode == .area ? .window : .area
            pending = nil
            hoverWindow = nil
            window?.invalidateCursorRects(for: self)
            if mode == .window, let window {
                updateHover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
            }
            needsDisplay = true
        case 36, 76: // Return / Enter
            if mode == .window {
                if let hoverWindow { onFinish?(.window(hoverWindow, viewRect(for: hoverWindow))) }
            } else if let pending {
                finishArea(pending)
            } else if let last = SelectionOverlayController.lastArea {
                pending = last.intersection(bounds)
                needsDisplay = true
            }
        case 123, 124, 125, 126: // ← → ↓ ↑
            guard mode == .area, dragStart == nil else { return }
            if pending == nil { pending = SelectionOverlayController.lastArea?.intersection(bounds) }
            guard var rect = pending else { return }
            let step: CGFloat = event.modifierFlags.contains(.option) ? 10 : 1
            let dx: CGFloat = event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0
            let dy: CGFloat = event.keyCode == 125 ? -step : event.keyCode == 126 ? step : 0
            if event.modifierFlags.contains(.shift) {
                rect.size.width = max(8, rect.width + dx)
                rect.size.height = max(8, rect.height + dy)
                rect.origin.y -= dy // grow downward, keeping the top edge put
            } else {
                rect.origin.x += dx
                rect.origin.y += dy
            }
            pending = rect.intersection(bounds)
            needsDisplay = true
        default:
            break
        }
    }

    private func finishArea(_ rect: CGRect) {
        SelectionOverlayController.lastArea = rect
        onFinish?(.rect(rect))
    }

    // Esc also arrives through the responder chain as cancelOperation.
    override func cancelOperation(_ sender: Any?) {
        onFinish?(.cancelled)
    }
}
