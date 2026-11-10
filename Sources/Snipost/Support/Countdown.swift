import AppKit
import SwiftUI

/// Self-timer: a big countdown near the bottom of the screen, so you can open
/// a menu or hover something before the screen is frozen. Click it to cancel.
@MainActor
enum Countdown {
    private static var panel: NSPanel?
    private static var cancelled = false

    /// Returns false if the user cancelled.
    static func run(seconds: Int) async -> Bool {
        guard seconds > 0 else { return true }
        cancelled = false
        let model = CountdownModel(remaining: seconds)
        show(model)
        defer { hide() }
        for remaining in stride(from: seconds, to: 0, by: -1) {
            model.remaining = remaining
            NSSound(named: "Tink")?.play()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if cancelled { return false }
        }
        hide()
        // Make sure the badge is gone before anything freezes the screen.
        try? await Task.sleep(nanoseconds: 90_000_000)
        return !cancelled
    }

    private static func show(_ model: CountdownModel) {
        hide()
        let hosting = NSHostingController(rootView: CountdownView(model: model) { cancelled = true; hide() })
        let size = NSSize(width: 120, height: 120)
        let badge = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        badge.isOpaque = false
        badge.backgroundColor = .clear
        badge.hasShadow = true
        badge.level = .statusBar
        badge.sharingType = .none
        badge.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        badge.isReleasedWhenClosed = false
        badge.contentViewController = hosting
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            badge.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 60))
        }
        badge.orderFrontRegardless()
        panel = badge
    }

    private static func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

@MainActor
private final class CountdownModel: ObservableObject {
    @Published var remaining: Int
    init(remaining: Int) { self.remaining = remaining }
}

private struct CountdownView: View {
    @ObservedObject var model: CountdownModel
    let cancel: () -> Void

    var body: some View {
        Button(action: cancel) {
            Text("\(model.remaining)")
                .font(.system(size: 52, weight: .semibold, design: .rounded).monospacedDigit())
                .contentTransition(.numericText(countsDown: true))
                .animation(.snappy, value: model.remaining)
                .frame(width: 104, height: 104)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help("Click to cancel")
        .padding(8)
    }
}
