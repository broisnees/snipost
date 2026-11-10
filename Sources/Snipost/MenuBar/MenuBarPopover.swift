import AppKit
import SwiftUI

/// The menu bar popover: capture modes as big tiles, record / AI-watch, live
/// session banner, and the most recent captures (draggable).
struct MenuBarPopover: View {
    let perform: (HotkeyAction) -> Void
    let openHistory: () -> Void
    let openSettings: () -> Void
    let openRecent: (URL) -> Void

    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var recording = RecordingController.shared
    @ObservedObject private var watch = WatchController.shared
    @State private var recents: [URL] = []

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if recording.isRecording || watch.isActive {
                liveBanner
            }

            LazyVGrid(columns: columns, spacing: 8) {
                tile(.area, "Area", "viewfinder")
                tile(.window, "Window", "macwindow")
                tile(.screen, "Screen", "display")
                tile(.scrolling, "Scrolling", "arrow.up.and.down.text.horizontal")
                tile(.ocrArea, "Copy Text", "text.viewfinder")
                tile(.plainArea, "Clipboard", "doc.on.clipboard")
            }

            HStack(spacing: 8) {
                wideTile(.record, "Record", "record.circle", tint: .red)
                wideTile(.watch, "Watch with AI", "eye", tint: .purple)
            }

            if !recents.isEmpty {
                recentStrip
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { recents = Array(HistoryStore.list().prefix(6)) }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 8) {
            BrandTile(size: 24)
            Text("Snipost")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            if prefs.replaceSystemScreenshots {
                Label("Default", systemImage: "checkmark.seal.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .help("Snipost handles ⌘⇧3 / ⌘⇧4 / ⌘⇧5")
            }
        }
    }

    private var liveBanner: some View {
        HStack(spacing: 8) {
            if recording.isRecording {
                Circle().fill(.red).frame(width: 8, height: 8)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("Recording · \(elapsed(context.date))")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                }
                Spacer()
                Button("Stop") { recording.stop() }
                    .controlSize(.small)
                    .tint(.red)
                    .buttonStyle(.borderedProminent)
            } else {
                Image(systemName: "eye").foregroundStyle(.purple)
                Text(watch.note ?? "Watching a region…")
                    .font(.system(size: 12))
                    .lineLimit(2)
                Spacer()
                Button("Stop") { watch.close() }
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    private var recentStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(recents, id: \.self) { url in
                    RecentThumb(url: url)
                        .onTapGesture { openRecent(url) }
                        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                        .contextMenu {
                            Button("Open in Editor") { openRecent(url) }
                            Button("Quick Look") { QuickLookWindow.show(url) }
                            Button("Copy") { FileActions.copy(url) }
                        }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            footerButton("History", "clock", action: openHistory)
            footerButton("Recordings", "film") {
                NSWorkspace.shared.open(RecordingController.recordingsDirectory)
            }
            Spacer()
            footerButton("Settings", "gearshape", action: openSettings)
            footerButton("Quit", "power") { NSApp.terminate(nil) }
        }
    }

    // MARK: Pieces

    private func tile(_ action: HotkeyAction, _ title: String, _ symbol: String) -> some View {
        Button { perform(action) } label: {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .regular))
                    .frame(height: 22)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                Text(shortcut(for: action))
                    .font(.system(size: 9.5).monospaced())
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .buttonStyle(TileStyle())
    }

    private func wideTile(_ action: HotkeyAction, _ title: String, _ symbol: String, tint: Color) -> some View {
        Button { perform(action) } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12, weight: .medium))
                    Text(shortcut(for: action))
                        .font(.system(size: 9.5).monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .buttonStyle(TileStyle())
    }

    private func footerButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
                .font(.system(size: 13))
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(TileStyle(idleOpacity: 0))
        .help(title)
    }

    /// System combos win the label when Snipost owns them.
    private func shortcut(for action: HotkeyAction) -> String {
        if prefs.replaceSystemScreenshots,
           let system = Preferences.systemHotkeys.first(where: { $0.1 == action }) {
            return system.0.display
        }
        return prefs.hotkey(for: action).display
    }

    private func elapsed(_ date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(recording.startedAt ?? date)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct TileStyle: ButtonStyle {
    var idleOpacity: Double = 0.06
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.16 : hovering ? 0.11 : idleOpacity))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}

private struct RecentThumb: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Color.primary.opacity(0.06)
            }
        }
        .frame(width: 47, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .contentShape(Rectangle())
        .task {
            let cg = await Task.detached(priority: .utility) {
                WallpaperLibrary.thumbnail(for: url, maxPixel: 140)
            }.value
            if let cg { image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)) }
        }
    }
}
