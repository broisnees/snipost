import AppKit

/// A screenshot pinned above everything else as a borderless floating window —
/// for keeping a reference on screen while you work elsewhere.
///
/// Drag it anywhere, scroll to resize, double-click or ⌘W / Esc to dismiss.
@MainActor
final class PinnedWindow: NSWindowController {
    /// Pins stay alive until dismissed, so something has to hold them.
    private static var open: [PinnedWindow] = []

    static func show(_ image: CGImage) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        var size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)

        // Never open a pin larger than most of the screen.
        if let visible = NSScreen.main?.visibleFrame {
            let limit = min(visible.width * 0.8 / size.width, visible.height * 0.8 / size.height, 1)
            size = NSSize(width: size.width * limit, height: size.height * limit)
        }

        let window = PinWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = PinView(image: image)
        window.center()

        let controller = PinnedWindow(window: window)
        open.append(controller)
        window.makeKeyAndOrderFront(nil)
    }

    static func dismiss(_ window: NSWindow) {
        window.orderOut(nil)
        open.removeAll { $0.window === window }
    }
}

/// Borderless windows refuse key status by default, which would swallow ⌘W.
private final class PinWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class PinView: NSView {
    private let image: CGImage

    init(image: CGImage) {
        self.image = image
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: bounds)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            dismiss()
        } else {
            super.mouseDown(with: event)
        }
    }

    /// Scroll to resize, keeping the aspect ratio and the window's centre.
    override func scrollWheel(with event: NSEvent) {
        guard let window else { return }
        let factor = 1 + event.scrollingDeltaY * 0.01
        guard factor > 0.5, factor < 1.5 else { return }
        let frame = window.frame
        let width = min(max(frame.width * factor, 80), 4000)
        let height = frame.height * (width / frame.width)
        window.setFrame(
            NSRect(
                x: frame.midX - width / 2,
                y: frame.midY - height / 2,
                width: width,
                height: height
            ),
            display: true
        )
    }

    override func keyDown(with event: NSEvent) {
        // Esc, or ⌘W.
        if event.keyCode == 53 || (event.charactersIgnoringModifiers == "w" && event.modifierFlags.contains(.command)) {
            dismiss()
            return
        }
        if event.charactersIgnoringModifiers == "c", event.modifierFlags.contains(.command) {
            Clipboard.copy(image)
            Toast.show("Copied to clipboard")
            return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copyImage), keyEquivalent: "c").target = self
        menu.addItem(withTitle: "Close", action: #selector(closePin), keyEquivalent: "w").target = self
        return menu
    }

    @objc private func copyImage() {
        Clipboard.copy(image)
        Toast.show("Copied to clipboard")
    }

    @objc private func closePin() {
        dismiss()
    }

    private func dismiss() {
        guard let window else { return }
        PinnedWindow.dismiss(window)
    }
}
