import AVFoundation
import AppKit
import Quartz
import SwiftUI

/// Full-size Quick Look viewer for a capture or recording (QLPreviewView plays
/// video with scrubbing and shows images at native size). Space or Esc closes.
@MainActor
enum QuickLookWindow {
    private static var window: NSWindow?

    static func show(_ url: URL, onEdit: (() -> Void)? = nil) {
        window?.close()

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let natural = naturalSize(of: url) ?? NSSize(width: 960, height: 600)
        let maxSize = NSSize(width: screen.width * 0.72, height: screen.height * 0.72 - 44)
        let fit = min(1, maxSize.width / natural.width, maxSize.height / natural.height)
        let contentSize = NSSize(
            width: max(420, natural.width * fit),
            height: max(240, natural.height * fit) + 44
        )

        let hosting = NSHostingController(rootView: QuickLookView(url: url, onEdit: onEdit.map { edit in
            { close(); edit() }
        }))
        let newWindow = QuickLookPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        newWindow.title = url.lastPathComponent
        newWindow.titlebarAppearsTransparent = true
        newWindow.isReleasedWhenClosed = false
        newWindow.level = .floating
        newWindow.contentViewController = hosting
        newWindow.setContentSize(contentSize)
        newWindow.center()

        NSApp.activate(ignoringOtherApps: true)
        newWindow.makeKeyAndOrderFront(nil)
        window = newWindow
    }

    static func close() {
        window?.close()
        window = nil
    }

    private static func naturalSize(of url: URL) -> NSSize? {
        if ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) {
            let asset = AVURLAsset(url: url)
            guard let track = asset.tracks(withMediaType: .video).first else { return nil }
            let size = track.naturalSize.applying(track.preferredTransform)
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            return NSSize(width: abs(size.width) / scale, height: abs(size.height) / scale)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let h = props[kCGImagePropertyPixelHeight] as? CGFloat
        else { return nil }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        return NSSize(width: w / scale, height: h / scale)
    }
}

private final class QuickLookPanel: NSWindow {
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 || event.keyCode == 53 { // Space, Esc
            close()
        } else {
            super.keyDown(with: event)
        }
    }
}

private struct QuickLookView: View {
    let url: URL
    let onEdit: (() -> Void)?

    var body: some View {
        if FileActions.isVideo(url) {
            VideoPreviewBody(url: url)
        } else {
            imageBody
        }
    }

    private var imageBody: some View {
        VStack(spacing: 0) {
            QLPreview(url: url)
            HStack(spacing: 8) {
                Text(url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let onEdit {
                    Button("Edit", systemImage: "slider.horizontal.3", action: onEdit)
                }
                Button("Copy", systemImage: "doc.on.doc") {
                    FileActions.copy(url)
                    Toast.show("Copied")
                }
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                Button("Open", systemImage: "arrow.up.forward.app") {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .frame(height: 44)
        }
    }
}

private struct QLPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.shouldCloseWithWindow = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url {
            view.previewItem = url as NSURL
        }
    }
}

/// File-level actions shared by thumbnails, Quick Look and the menu bar.
enum FileActions {
    static func copy(_ url: URL) {
        // One item carrying both the file and (for images) its PNG data.
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        if !isVideo(url), let data = try? Data(contentsOf: url) {
            item.setData(data, forType: .png)
            if let tiff = NSImage(data: data)?.tiffRepresentation {
                item.setData(tiff, forType: .tiff)
            }
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    static func isVideo(_ url: URL) -> Bool {
        ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased())
    }

    /// First frame of a video, for thumbnails.
    static func posterFrame(of url: URL) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        guard let (image, _) = try? await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)) else {
            return nil
        }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    private static var lastStaged: (image: CGImage, url: URL)?

    /// Thread-safe: writes already-encoded PNG bytes to the staging folder.
    nonisolated static func writeStaged(_ png: Data) -> URL? {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Snipost/Staged", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = dir.appendingPathComponent("Snipost \(formatter.string(from: Date())).png")
        return (try? png.write(to: url)) != nil ? url : nil
    }

    /// Writes a rendered capture where it can be dragged out / Quick Looked.
    /// The same image staged twice (copy + thumbnail) is encoded once.
    @MainActor
    static func stage(_ image: CGImage, pngData: Data? = nil) -> URL? {
        if let lastStaged, lastStaged.image === image,
           FileManager.default.fileExists(atPath: lastStaged.url.path) {
            return lastStaged.url
        }
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Snipost/Staged", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Keep the staging folder from growing forever.
        if let old = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey]) {
            let cutoff = Date().addingTimeInterval(-86_400)
            for url in old {
                let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                if created < cutoff { try? FileManager.default.removeItem(at: url) }
            }
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = dir.appendingPathComponent("Snipost \(formatter.string(from: Date())).png")
        let ok: Bool
        if let pngData {
            ok = (try? pngData.write(to: url)) != nil
        } else {
            ok = ImageWriter.write(image, to: url.path)
        }
        guard ok else { return nil }
        lastStaged = (image, url)
        return url
    }
}
