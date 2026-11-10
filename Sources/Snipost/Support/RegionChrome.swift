import AppKit
import SwiftUI

/// On-screen chrome for a live region (recording, AI watch): a click-through
/// border around the area plus a floating, draggable HUD next to it. Both
/// windows are hidden from screen capture.
@MainActor
final class RegionChrome {
    private let border: NSPanel
    private let hud: NSPanel

    init<HUD: View>(region: NSRect, tint: NSColor, dashed: Bool, @ViewBuilder hud content: () -> HUD) {
        let inset: CGFloat = -4
        border = NSPanel(
            contentRect: region.insetBy(dx: inset, dy: inset),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        border.isOpaque = false
        border.backgroundColor = .clear
        border.hasShadow = false
        border.ignoresMouseEvents = true
        border.level = .statusBar
        border.sharingType = .none
        border.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        border.isReleasedWhenClosed = false
        border.contentView = RegionBorderView(tint: tint, dashed: dashed)
        border.orderFrontRegardless()

        let hosting = NSHostingController(rootView: content())
        hosting.sizingOptions = [.preferredContentSize]
        let size = hosting.view.fittingSize
        hud = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        hud.isOpaque = false
        hud.backgroundColor = .clear
        hud.hasShadow = true
        hud.level = .statusBar
        hud.sharingType = .none
        hud.isMovableByWindowBackground = true
        hud.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hud.isReleasedWhenClosed = false
        hud.contentViewController = hosting
        hud.setFrameOrigin(Self.hudOrigin(for: region, size: size))
        hud.alphaValue = 0
        hud.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            hud.animator().alphaValue = 1
        }
    }

    /// Gives the HUD keyboard focus (for text fields) without activating the
    /// app behind it.
    func focusHUD() {
        hud.makeKey()
    }

    func close() {
        border.orderOut(nil)
        hud.orderOut(nil)
    }

    /// Below the region if it fits, else above, else tucked inside the top.
    private static func hudOrigin(for region: NSRect, size: NSSize) -> NSPoint {
        let screen = NSScreen.screens.first { $0.frame.intersects(region) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? region
        let gap: CGFloat = 14
        var y = region.minY - size.height - gap
        if y < visible.minY {
            y = region.maxY + gap
            if y + size.height > visible.maxY {
                y = region.maxY - size.height - gap
            }
        }
        let x = min(max(region.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        return NSPoint(x: x, y: y)
    }
}

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class RegionBorderView: NSView {
    let tint: NSColor
    let dashed: Bool

    init(tint: NSColor, dashed: Bool) {
        self.tint = tint
        self.dashed = dashed
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 4, yRadius: 4)
        path.lineWidth = 2
        if dashed { path.setLineDash([8, 5], count: 2, phase: 0) }
        tint.withAlphaComponent(0.95).setStroke()
        path.stroke()
    }
}

// MARK: - HUDs

/// Shared pill styling for region HUDs.
struct HUDCapsule<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
            .padding(8) // room for the window shadow
    }
}

struct HUDIconButton: View {
    let symbol: String
    let help: String
    var tint: Color = .primary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.08)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct RecordingHUD: View {
    @ObservedObject var controller: RecordingController
    let onStop: () -> Void
    let onCancel: () -> Void

    @State private var pulse = false

    var body: some View {
        HUDCapsule {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 9, height: 9)
                    .opacity(pulse ? 0.35 : 1)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                    .onAppear { pulse = true }

                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    Text(elapsed(at: context.date))
                        .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                        .frame(minWidth: 44, alignment: .leading)
                }

                HUDIconButton(symbol: "stop.fill", help: "Stop and save", tint: .red, action: onStop)
                HUDIconButton(symbol: "xmark", help: "Discard recording", action: onCancel)
            }
        }
    }

    private func elapsed(at date: Date) -> String {
        guard let start = controller.startedAt else { return "0:00" }
        let seconds = max(0, Int(date.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
