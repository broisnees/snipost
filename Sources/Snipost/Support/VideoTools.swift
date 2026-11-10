import AVFoundation
import AVKit
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Recording tools for the preview window: QuickTime-style trimming (in
/// place) and GIF export sized for Slack/GitHub.
@MainActor
final class VideoEditorModel: ObservableObject {
    @Published private(set) var url: URL
    @Published private(set) var busy: String?

    let playerView: AVPlayerView

    init(url: URL) {
        self.url = url
        playerView = AVPlayerView()
        playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = false
        playerView.player = AVPlayer(url: url)
    }

    var canTrim: Bool { busy == nil && playerView.canBeginTrimming }

    func trim() {
        guard canTrim else { return }
        playerView.beginTrimming { [weak self] result in
            guard result == .okButton else { return }
            Task { @MainActor in self?.applyTrim() }
        }
    }

    private func applyTrim() {
        guard let item = playerView.player?.currentItem else { return }
        let start = item.reversePlaybackEndTime.isValid ? item.reversePlaybackEndTime : .zero
        let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime : item.duration
        let range = CMTimeRange(start: start, end: end)
        guard range.duration.seconds > 0.05 else { return }
        busy = "Trimming…"
        let source = url
        Task { @MainActor in
            do {
                try await VideoExport.trim(source, to: range)
                // Reload the trimmed file in place.
                playerView.player = AVPlayer(url: source)
                Toast.show("Trimmed")
            } catch {
                Toast.show("Trim failed: \(error.localizedDescription)")
            }
            busy = nil
        }
    }

    func exportGIF(_ preset: GIFPreset) {
        guard busy == nil else { return }
        busy = "Making GIF…"
        let source = url
        Task { @MainActor in
            do {
                let gif = try await VideoExport.gif(from: source, preset: preset)
                FileActions.copy(gif)
                Toast.show("GIF copied — \(ByteCountFormatter.string(fromByteCount: gif.fileSize, countStyle: .file))")
                NSWorkspace.shared.activateFileViewerSelecting([gif])
            } catch {
                Toast.show("GIF export failed: \(error.localizedDescription)")
            }
            busy = nil
        }
    }
}

enum GIFPreset: String, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }

    var width: CGFloat {
        switch self {
        case .small: return 480
        case .medium: return 720
        case .large: return 960
        }
    }

    var fps: Double {
        switch self {
        case .small: return 10
        case .medium: return 12
        case .large: return 15
        }
    }

    var title: String {
        switch self {
        case .small: return "Small — 480 px, 10 fps (Slack)"
        case .medium: return "Medium — 720 px, 12 fps (GitHub)"
        case .large: return "Large — 960 px, 15 fps"
        }
    }
}

enum VideoExport {
    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    /// Re-encodes `range` of the file and swaps it in place (frame-accurate,
    /// unlike passthrough which snaps to keyframes).
    static func trim(_ url: URL, to range: CMTimeRange) async throws {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw Failure(errorDescription: "can't create an export session")
        }
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).mp4")
        session.outputURL = temp
        session.outputFileType = .mp4
        session.timeRange = range
        session.shouldOptimizeForNetworkUse = true
        await withCheckedContinuation { continuation in
            session.exportAsynchronously { continuation.resume() }
        }
        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: temp)
            throw Failure(errorDescription: session.error?.localizedDescription ?? "export failed")
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    }

    /// Samples frames at the preset's fps and width into a looping GIF next
    /// to the video. Off the main thread end to end.
    static func gif(from url: URL, preset: GIFPreset) async throws -> URL {
        let output = url.deletingPathExtension().appendingPathExtension("gif")
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw Failure(errorDescription: "empty video") }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: preset.width, height: preset.width * 4)
        let tolerance = CMTime(seconds: 0.5 / preset.fps, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let frameCount = max(1, Int(duration * preset.fps))
        let times = (0..<frameCount).map { CMTime(seconds: Double($0) / preset.fps, preferredTimescale: 600) }

        try? FileManager.default.removeItem(at: output)
        guard let destination = CGImageDestinationCreateWithURL(
            output as CFURL, UTType.gif.identifier as CFString, frameCount, nil
        ) else { throw Failure(errorDescription: "can't create GIF file") }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / preset.fps],
        ] as CFDictionary

        var added = 0
        for await result in generator.images(for: times) {
            if let image = try? result.image {
                CGImageDestinationAddImage(destination, image, frameProperties)
                added += 1
            }
        }
        guard added > 0, CGImageDestinationFinalize(destination) else {
            throw Failure(errorDescription: "no frames could be read")
        }
        return output
    }
}

extension URL {
    var fileSize: Int64 {
        (try? resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }
}

/// Preview-window body for recordings: player with QuickTime-style trim,
/// GIF export, and the usual file actions.
struct VideoPreviewBody: View {
    @StateObject private var model: VideoEditorModel

    init(url: URL) {
        _model = StateObject(wrappedValue: VideoEditorModel(url: url))
    }

    var body: some View {
        VStack(spacing: 0) {
            PlayerViewHost(view: model.playerView)
                .overlay(alignment: .top) {
                    if let busy = model.busy {
                        Label(busy, systemImage: "hourglass")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.regularMaterial, in: Capsule())
                            .padding(10)
                    }
                }
            HStack(spacing: 8) {
                Text(model.url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Trim", systemImage: "timeline.selection") { model.trim() }
                    .help("Trim the start and end (saved in place)")
                Menu {
                    ForEach(GIFPreset.allCases) { preset in
                        Button(preset.title) { model.exportGIF(preset) }
                    }
                } label: {
                    Label("GIF", systemImage: "photo.stack")
                }
                .fixedSize()
                .help("Export a looping GIF and copy it")
                Button("Copy", systemImage: "doc.on.doc") {
                    FileActions.copy(model.url)
                    Toast.show("Recording copied")
                }
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.url])
                }
            }
            .disabled(model.busy != nil)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .frame(height: 44)
        }
    }
}

private struct PlayerViewHost: NSViewRepresentable {
    let view: AVPlayerView
    func makeNSView(context: Context) -> AVPlayerView { view }
    func updateNSView(_ nsView: AVPlayerView, context: Context) {}
}
