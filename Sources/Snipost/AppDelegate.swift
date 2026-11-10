import AppKit
import Carbon.HIToolbox
import AVFoundation
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let hotkeys = HotkeyManager()
    private var editors: [EditorWindowController] = []
    private let popover = NSPopover()
    private var cancellables: Set<AnyCancellable> = []
    private var statusTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Trigger the system Screen Recording prompt once so the app registers
        // itself in Privacy & Security. Asking on every launch would nag users
        // whose permission state macOS reports lazily.
        let requestedKey = "didRequestScreenAccess"
        if !CGPreflightScreenCaptureAccess(), !UserDefaults.standard.bool(forKey: requestedKey) {
            UserDefaults.standard.set(true, forKey: requestedKey)
            CGRequestScreenCaptureAccess()
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = BrandMark.menuBarImage()
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        popover.behavior = .transient
        popover.animates = true

        // Snipost owns ⌘⇧3/4/5 only while it runs — re-claim them on launch
        // (they're handed back to macOS on quit).
        if Preferences.shared.replaceSystemScreenshots, !SystemShortcuts.systemShortcutsDisabled {
            SystemShortcuts.setSystemShortcutsEnabled(false)
        }

        reloadHotkeysAndMenu()

        // Warm the agent PATH lookup off the main thread.
        Task.detached(priority: .utility) { _ = AgentRunner.searchPath }

        RecordingController.shared.onFinished = { [weak self] url in
            self?.handleRecording(url)
        }
        RecordingController.shared.$startedAt
            .combineLatest(WatchController.shared.$phase)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.updateStatusItem() }
            .store(in: &cancellables)

        // Users who connected Drive before auto-sync existed get it enabled
        // once too.
        if DriveService.shared.isConnected {
            Preferences.shared.enableDriveSyncDefaultsOnce()
        }

        NotificationCenter.default.addObserver(
            forName: .snipostHotkeysChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reloadHotkeysAndMenu() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if Preferences.shared.replaceSystemScreenshots {
            SystemShortcuts.setSystemShortcutsEnabled(true)
        }
    }

    private func reloadHotkeysAndMenu() {
        hotkeys.unregisterAll()
        for action in HotkeyAction.allCases {
            let hotkey = Preferences.shared.hotkey(for: action)
            hotkeys.register(keyCode: hotkey.keyCode, modifiers: hotkey.carbonModifiers) { [weak self] in
                self?.perform(action)
            }
        }
        if Preferences.shared.replaceSystemScreenshots {
            for (hotkey, action) in Preferences.systemHotkeys {
                hotkeys.register(keyCode: hotkey.keyCode, modifiers: hotkey.carbonModifiers) { [weak self] in
                    self?.perform(action)
                }
            }
        }
    }

    // MARK: Status item

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            popover.performClose(nil)
            statusItem.menu = buildMenu()
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
            return
        }
        // While recording, the menu bar item is the stop button.
        if RecordingController.shared.isRecording {
            RecordingController.shared.stop()
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        let view = MenuBarPopover(
            perform: { [weak self] action in self?.performFromPopover(action) },
            openHistory: { [weak self] in self?.popover.performClose(nil); self?.openHistory() },
            openSettings: { [weak self] in self?.popover.performClose(nil); self?.openSettings() },
            openRecent: { [weak self] url in
                self?.popover.performClose(nil)
                if let image = CaptureService.loadCGImage(at: url) { self?.openEditor(with: image) }
            }
        )
        popover.contentViewController = NSHostingController(rootView: view)
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    /// Close the popover first so it isn't in the frozen frame.
    private func performFromPopover(_ action: HotkeyAction) {
        popover.animates = false
        popover.performClose(nil)
        popover.animates = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.perform(action)
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        statusTimer?.invalidate()
        statusTimer = nil

        if let start = RecordingController.shared.startedAt {
            let symbol = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop recording")
            let config = NSImage.SymbolConfiguration(paletteColors: [.white, .systemRed])
            button.image = symbol?.withSymbolConfiguration(config)
            let tick = { [weak button] in
                let seconds = max(0, Int(Date().timeIntervalSince(start)))
                button?.title = String(format: " %d:%02d", seconds / 60, seconds % 60)
            }
            tick()
            statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { tick() }
            }
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        } else if WatchController.shared.isActive {
            button.image = NSImage(systemSymbolName: "eye.circle.fill", accessibilityDescription: "Watching")
            button.title = ""
        } else {
            button.image = BrandMark.menuBarImage()
            button.title = ""
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        addCaptureItem(to: menu, title: "Capture Area", hotkeyAction: .area, action: #selector(captureArea))
        addCaptureItem(to: menu, title: "Capture Window", hotkeyAction: .window, action: #selector(captureWindow))
        addCaptureItem(to: menu, title: "Capture Full Screen", hotkeyAction: .screen, action: #selector(captureScreen))
        addCaptureItem(to: menu, title: "Snip to Clipboard", hotkeyAction: .plainArea, action: #selector(plainSnip))
        addCaptureItem(to: menu, title: "Scrolling Capture", hotkeyAction: .scrolling, action: #selector(scrollingCapture))
        addCaptureItem(to: menu, title: "OCR Snip", hotkeyAction: .ocrArea, action: #selector(ocrSnip))
        menu.addItem(.separator())
        addCaptureItem(
            to: menu,
            title: RecordingController.shared.isRecording ? "Stop Recording" : "Record Region",
            hotkeyAction: .record,
            action: #selector(recordRegion)
        )
        addCaptureItem(
            to: menu,
            title: WatchController.shared.isActive ? "Stop Watching" : "Watch Region with AI",
            hotkeyAction: .watch,
            action: #selector(watchRegion)
        )

        menu.addItem(.separator())

        let history = NSMenuItem(title: "History…", action: #selector(openHistory), keyEquivalent: "")
        history.target = self
        menu.addItem(history)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Snipost", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        return menu
    }

    private func addCaptureItem(to menu: NSMenu, title: String, hotkeyAction: HotkeyAction, action: Selector) {
        let hotkey = Preferences.shared.hotkey(for: hotkeyAction)
        let item = NSMenuItem(title: title, action: action, keyEquivalent: hotkey.menuKeyEquivalent)
        item.keyEquivalentModifierMask = hotkey.nsModifiers
        item.target = self
        menu.addItem(item)
    }

    @objc private func captureArea() { perform(.area) }
    @objc private func captureWindow() { perform(.window) }
    @objc private func captureScreen() { perform(.screen) }
    @objc private func plainSnip() { perform(.plainArea) }
    @objc private func scrollingCapture() { perform(.scrolling) }
    @objc private func ocrSnip() { perform(.ocrArea) }
    @objc private func recordRegion() { perform(.record) }
    @objc private func watchRegion() { perform(.watch) }
    @objc private func openSettings() { SettingsWindowController.shared.show() }

    @objc private func openHistory() {
        HistoryWindowController.show { [weak self] url in
            guard let self, let image = CaptureService.loadCGImage(at: url) else { return }
            self.openEditor(with: image)
        }
    }

    private func perform(_ action: HotkeyAction) {
        // Self-timer for screenshot modes: count down first, then freeze.
        let timed: Set<HotkeyAction> = [.area, .window, .screen, .plainArea, .plainScreen, .ocrArea, .lastArea]
        let delay = Preferences.shared.captureDelay
        if delay > 0, timed.contains(action) {
            PendingFrozenFrame.clear() // the pre-countdown frame is stale by now
            Task { @MainActor in
                if await Countdown.run(seconds: delay) { self.performNow(action) }
            }
            return
        }
        performNow(action)
    }

    private func performNow(_ action: HotkeyAction) {
        switch action {
        case .record:
            RecordingController.shared.toggle()
            return
        case .watch:
            WatchController.shared.toggle()
            return
        case .captureBar:
            CaptureBar.toggle { [weak self] picked in self?.perform(picked) }
            return
        case .lastArea:
            CaptureService.captureLastArea { [weak self] image in
                guard let self, let image else { return }
                self.handleCaptured(image)
            }
            return
        default:
            break
        }
        if action == .scrolling {
            CaptureService.captureScrolling { [weak self] image in
                guard let self, let image else { return }
                self.handleCaptured(image)
            }
            return
        }
        CaptureService.capture(action.captureKind) { [weak self] image in
            guard let self, let image else { return }
            switch action {
            case .plainArea, .plainScreen:
                // Plain snip: the raw screenshot, straight to the clipboard —
                // but it still counts as a capture for history and Drive sync.
                Clipboard.copy(image)
                Toast.show("Copied to clipboard")
                if Preferences.shared.saveHistory {
                    HistoryStore.save(image)
                }
                if Preferences.shared.autoUploadToDrive, DriveService.shared.isConnected {
                    self.autoUploadQuietly(image)
                }
            case .ocrArea:
                self.recognizeAndCopyText(from: image)
            default:
                self.handleCaptured(image)
            }
        }
    }

    /// OCR snip: recognized text straight to the clipboard, no editor.
    private func recognizeAndCopyText(from image: CGImage) {
        Task { @MainActor in
            let text = await TextRecognizer.recognize(in: image)
            if text.isEmpty {
                Toast.show("No text found")
            } else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                let preview = text.replacingOccurrences(of: "\n", with: " ").prefix(42)
                Toast.show("Text copied — “\(preview)\(text.count > 42 ? "…" : "")”")
            }
        }
    }

    private func handleCaptured(_ image: CGImage) {
        let prefs = Preferences.shared
        if prefs.saveHistory {
            HistoryStore.save(image)
        }
        if prefs.autoUploadToDrive, DriveService.shared.isConnected,
           let rendered = defaultRender(image) {
            autoUploadQuietly(rendered)
        }

        switch prefs.captureFlow {
        case .editor:
            openEditor(with: image)
            if prefs.autoCopy || prefs.autoSaveToDesktop {
                autoProcess(image, copy: prefs.autoCopy, save: prefs.autoSaveToDesktop, toast: false)
            }

        case .thumbnail:
            guard let rendered = defaultRender(image) else { return }
            if prefs.autoCopy { Clipboard.copy(rendered) }
            if prefs.autoSaveToDesktop { saveToDesktop(rendered) }
            FloatingThumbnail.show(rendered: rendered, actions: FloatingThumbnail.Actions(
                onEdit: { [weak self] in self?.openEditor(with: image) },
                onCopy: { Clipboard.copy(rendered); Toast.show("Copied to clipboard") },
                onSave: { [weak self] in
                    self?.saveToDesktop(rendered)
                    Toast.show("Saved to Desktop")
                },
                onDrive: { [weak self] in self?.uploadToDrive(rendered) }
            ))

        case .instant:
            // Never drop a capture on the floor — copy even if both toggles
            // are off unless the user opted into save-only.
            let copy = prefs.autoCopy || !prefs.autoSaveToDesktop
            autoProcess(image, copy: copy, save: prefs.autoSaveToDesktop, toast: true)
        }
    }

    private func handleRecording(_ url: URL) {
        if Preferences.shared.autoCopyRecordings {
            FileActions.copy(url)
            Toast.show("Recording copied to clipboard")
        }
        Task { @MainActor in
            let poster = await FileActions.posterFrame(of: url)
                ?? NSImage(systemSymbolName: "film", accessibilityDescription: nil)!
            let asset = AVURLAsset(url: url)
            let seconds = (try? await asset.load(.duration).seconds) ?? 0
            let badge = seconds.isFinite ? String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60) : nil
            FloatingThumbnail.show(
                FloatingThumbnail.Item(preview: poster, fileURL: url, isVideo: true, badge: badge),
                actions: FloatingThumbnail.Actions(
                    onCopy: { FileActions.copy(url); Toast.show("Recording copied") },
                    onSave: { NSWorkspace.shared.activateFileViewerSelecting([url]) },
                    onDelete: {
                        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
                        Toast.show("Moved to Trash")
                    }
                )
            )
        }
    }

    /// What a capture becomes outside the editor: the raw screenshot, unless
    /// the user opted into automatic styling.
    private func defaultRender(_ image: CGImage) -> CGImage? {
        guard Preferences.shared.beautifyByDefault else { return image }
        return BeautifyRenderer.render(
            image: image,
            settings: BeautifySettings(),
            autoColors: ColorAnalysis.autoGradient(for: image)
        )
    }

    private func saveToDesktop(_ rendered: CGImage) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let url = desktop.appendingPathComponent("Snipost \(formatter.string(from: Date())).png")
        _ = ImageWriter.write(rendered, to: url.path)
    }

    /// Background sync for the "upload every capture" preference — no
    /// clipboard changes; confirmation via toast + optional notification.
    private func autoUploadQuietly(_ rendered: CGImage) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let filename = "Snipost \(formatter.string(from: Date())).png"
        Task { @MainActor in
            do {
                _ = try await DriveService.shared.uploadAndLink(rendered, filename: filename)
                Toast.show("Synced to Drive")
                if Preferences.shared.notifyOnDriveUpload {
                    Notifier.notify(title: "Uploaded to Google Drive", body: filename)
                }
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                Toast.show("Drive sync failed")
                if Preferences.shared.notifyOnDriveUpload {
                    Notifier.notify(title: "Drive sync failed", body: reason)
                }
            }
        }
    }

    private func uploadToDrive(_ rendered: CGImage) {
        guard DriveService.shared.isConnected else {
            Toast.show("Connect Google Drive in Settings → Accounts")
            SettingsWindowController.shared.show()
            return
        }
        Toast.show("Uploading to Drive…")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let filename = "Snipost \(formatter.string(from: Date())).png"
        Task { @MainActor in
            do {
                let link = try await DriveService.shared.uploadAndLink(rendered, filename: filename)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link, forType: .string)
                Toast.show("Drive link copied")
                if Preferences.shared.notifyOnDriveUpload {
                    Notifier.notify(title: "Uploaded to Google Drive", body: "Share link copied — \(filename)")
                }
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                Toast.show("Drive upload failed")
                if Preferences.shared.notifyOnDriveUpload {
                    Notifier.notify(title: "Drive upload failed", body: reason)
                }
            }
        }
    }

    /// Beautifies with default settings and copies/saves without the editor.
    private func autoProcess(_ image: CGImage, copy: Bool, save: Bool, toast: Bool) {
        guard let rendered = defaultRender(image) else { return }
        var notes: [String] = []
        if copy {
            Clipboard.copy(rendered)
            notes.append("Copied to clipboard")
        }
        if save {
            saveToDesktop(rendered)
            notes.append("Saved to Desktop")
        }
        if toast, !notes.isEmpty {
            Toast.show(notes.joined(separator: " · "))
        }
    }

    private func openEditor(with image: CGImage) {
        let controller = EditorWindowController(image: image)
        editors.append(controller)

        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)

        if let window = controller.window {
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.editors.removeAll { $0 === controller }
            }
        }
    }
}
