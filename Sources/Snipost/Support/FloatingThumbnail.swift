import AppKit
import SwiftUI

/// After a capture or recording, a small card slides into the bottom-right
/// corner: drag it straight into any app, click to Quick Look, Space to
/// preview, or use the quick actions. Auto-dismisses unless hovered.
@MainActor
enum FloatingThumbnail {
    private static var panel: ThumbnailPanel?
    private static var hovering = false

    struct Item {
        var preview: NSImage
        /// On-disk file — enables drag-out and Quick Look.
        var fileURL: URL?
        var isVideo = false
        var badge: String?
    }

    struct Actions {
        var onEdit: (() -> Void)?
        var onCopy: () -> Void
        var onSave: (() -> Void)?
        var onDrive: (() -> Void)?
        var onDelete: (() -> Void)?
    }

    /// Image capture convenience (keeps the old call shape).
    static func show(rendered: CGImage, actions: Actions) {
        let preview = NSImage(cgImage: rendered, size: NSSize(width: rendered.width, height: rendered.height))
        show(Item(preview: preview, fileURL: FileActions.stage(rendered)), actions: actions)
    }

    static func show(_ item: Item, actions: Actions) {
        hide(animated: false)

        let quickLook: () -> Void = {
            guard let url = item.fileURL else { actions.onEdit?(); return }
            hide()
            QuickLookWindow.show(url, onEdit: actions.onEdit)
        }

        let view = ThumbnailView(
            item: item,
            onQuickLook: quickLook,
            onEdit: actions.onEdit.map { edit in { hide(); edit() } },
            onCopy: { actions.onCopy(); hide() },
            onSave: actions.onSave.map { save in { save(); hide() } },
            onDrive: actions.onDrive,
            onDelete: actions.onDelete.map { delete in { delete(); hide() } },
            onClose: { hide() },
            onHover: { inside in
                hovering = inside
                if inside { panel?.makeKey() } // so Space reaches the card
            }
        )

        let hosting = NSHostingController(rootView: view)
        let size = hosting.view.fittingSize
        let newPanel = ThumbnailPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.onSpace = quickLook
        newPanel.onEscape = { hide() }
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.level = .floating
        newPanel.hasShadow = true
        newPanel.isReleasedWhenClosed = false
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.contentViewController = hosting

        var finalOrigin = NSPoint.zero
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            finalOrigin = NSPoint(x: visible.maxX - size.width - 16, y: visible.minY + 16)
        }

        // Enter: slide in from the right edge + fade.
        newPanel.setFrameOrigin(NSPoint(x: finalOrigin.x + 24, y: finalOrigin.y))
        newPanel.alphaValue = 0
        newPanel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.26
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            newPanel.animator().alphaValue = 1
            newPanel.animator().setFrameOrigin(finalOrigin)
        }

        panel = newPanel
        hovering = false
        scheduleDismiss(for: newPanel, after: item.isVideo ? 12 : 8)
    }

    static func hide(animated: Bool = true) {
        guard let dismissing = panel else { return }
        panel = nil
        guard animated else {
            dismissing.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            dismissing.animator().alphaValue = 0
        }, completionHandler: {
            dismissing.orderOut(nil)
        })
    }

    private static func scheduleDismiss(for target: NSPanel, after seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            guard panel === target else { return }
            if hovering {
                scheduleDismiss(for: target, after: 3)
            } else {
                hide()
            }
        }
    }
}

private final class ThumbnailPanel: NSPanel {
    var onSpace: (() -> Void)?
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: onSpace?()
        case 53: onEscape?()
        default: super.keyDown(with: event)
        }
    }
}

private struct ThumbnailView: View {
    let item: FloatingThumbnail.Item
    let onQuickLook: () -> Void
    let onEdit: (() -> Void)?
    let onCopy: () -> Void
    let onSave: (() -> Void)?
    let onDrive: (() -> Void)?
    let onDelete: (() -> Void)?
    let onClose: () -> Void
    let onHover: (Bool) -> Void

    @State private var hovered = false

    var body: some View {
        VStack(spacing: 8) {
            preview
            HStack(spacing: 6) {
                thumbButton("eye", "Quick Look (Space)", action: onQuickLook)
                if let onEdit { thumbButton("slider.horizontal.3", "Edit", action: onEdit) }
                thumbButton("doc.on.doc", "Copy", action: onCopy)
                if let onSave {
                    thumbButton(item.isVideo ? "folder" : "square.and.arrow.down",
                                item.isVideo ? "Show in Finder" : "Save to Desktop", action: onSave)
                }
                if let onDrive { thumbButton("icloud.and.arrow.up", "Upload to Drive", action: onDrive) }
                if let onDelete { thumbButton("trash", "Delete", action: onDelete) }
            }
        }
        .padding(10)
        .focusEffectDisabled()
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .padding(6)
        .onHover { inside in
            hovered = inside
            onHover(inside)
        }
    }

    /// Explicit size: a max-only frame collapses to zero in fittingSize.
    private var previewSize: CGSize {
        let w = max(item.preview.size.width, 1), h = max(item.preview.size.height, 1)
        let scale = min(256 / w, 160 / h)
        return CGSize(width: max(120, w * scale), height: max(68, h * scale))
    }

    private var preview: some View {
        ZStack {
            Image(nsImage: item.preview)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: previewSize.width, height: previewSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))

            if item.isVideo {
                Image(systemName: "play.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(.black.opacity(0.5)))
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let badge = item.badge {
                Text(badge)
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.black.opacity(0.6)))
                    .padding(6)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.white, .black.opacity(0.55))
            }
            .buttonStyle(.plain)
            .padding(5)
            .opacity(hovered ? 1 : 0)
        }
        .overlay(alignment: .bottomTrailing) {
            if hovered, item.fileURL != nil {
                Label("Drag", systemImage: "hand.draw")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.black.opacity(0.5)))
                    .padding(6)
                    .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onQuickLook)
        .onDrag {
            guard let url = item.fileURL else { return NSItemProvider() }
            return NSItemProvider(contentsOf: url) ?? NSItemProvider()
        }
        .help("Click or press Space to Quick Look · drag into any app")
    }

    private func thumbButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 36, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.07)))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(ThumbPressStyle())
        .focusable(false)
        .help(help)
    }
}

private struct ThumbPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
