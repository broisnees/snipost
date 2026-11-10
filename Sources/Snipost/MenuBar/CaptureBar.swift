import AppKit
import SwiftUI

/// The ⌘⇧5 bar: every capture mode — screenshots and recordings — in one
/// floating strip near the bottom of the screen, like macOS's own.
@MainActor
enum CaptureBar {
    private static var panel: KeyablePanel?

    static var isShown: Bool { panel != nil }

    static func toggle(perform: @escaping (HotkeyAction) -> Void) {
        if isShown { hide() } else { show(perform: perform) }
    }

    static func show(perform: @escaping (HotkeyAction) -> Void) {
        hide()
        let view = CaptureBarView(
            pick: { action in
                hide()
                // Let the bar vanish before the screen is frozen.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { perform(action) }
            },
            close: { hide() }
        )
        let hosting = NSHostingController(rootView: view)
        let size = hosting.view.fittingSize
        let bar = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        bar.isOpaque = false
        bar.backgroundColor = .clear
        bar.hasShadow = true
        bar.level = .statusBar
        bar.sharingType = .none
        bar.isMovableByWindowBackground = true
        bar.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        bar.isReleasedWhenClosed = false
        bar.contentViewController = hosting

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            bar.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 80))
        }
        bar.alphaValue = 0
        bar.orderFrontRegardless()
        bar.makeKey()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            bar.animator().alphaValue = 1
        }
        panel = bar
    }

    static func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct CaptureBarView: View {
    let pick: (HotkeyAction) -> Void
    let close: () -> Void
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        HStack(spacing: 4) {
            group("Screenshot") {
                item(.area, "Area", "viewfinder")
                item(.window, "Window", "macwindow")
                item(.screen, "Screen", "display")
                item(.scrolling, "Scrolling", "arrow.up.and.down.text.horizontal")
                item(.ocrArea, "Text", "text.viewfinder")
            }
            Divider().frame(height: 44).padding(.horizontal, 6)
            group("Record") {
                item(.record, "Record", "record.circle", tint: .red)
                item(.watch, "AI Watch", "eye", tint: .purple)
            }
            Divider().frame(height: 44).padding(.horizontal, 6)
            Menu {
                Picker("Timer", selection: $prefs.captureDelay) {
                    Text("No timer").tag(0)
                    Text("3 seconds").tag(3)
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                }
                .pickerStyle(.inline)
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: prefs.captureDelay > 0 ? "timer" : "timer")
                        .font(.system(size: 17))
                        .foregroundStyle(prefs.captureDelay > 0 ? Color.accentColor : .primary)
                        .frame(height: 20)
                    Text(prefs.captureDelay > 0 ? "\(prefs.captureDelay)s" : "Timer")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .frame(width: 56, height: 50)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Self-timer for screenshots")
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .padding(8)
        .focusEffectDisabled()
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) { content() }
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
        }
    }

    private func item(_ action: HotkeyAction, _ title: String, _ symbol: String, tint: Color = .primary) -> some View {
        Button { pick(action) } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 17))
                    .foregroundStyle(tint)
                    .frame(height: 20)
                Text(title).font(.system(size: 10.5, weight: .medium))
            }
            .frame(width: 64, height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(BarButtonStyle())
        .focusable(false)
    }
}

private struct BarButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.16 : hovering ? 0.09 : 0))
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}
