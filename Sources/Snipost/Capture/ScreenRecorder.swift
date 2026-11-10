import AVFoundation
import AppKit
import ScreenCaptureKit

/// Records one screen region to an H.264 .mp4 with ScreenCaptureKit +
/// AVAssetWriter. Snipost's own windows (border, HUD) are excluded from the
/// stream, so the chrome never ends up in the video.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let outputURL: URL

    private let queue = DispatchQueue(label: "app.snipost.recorder", qos: .userInitiated)
    private var stream: SCStream?
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private var audioInput: AVAssetWriterInput?
    private var sessionStarted = false // touched only on `queue`

    init(region: CaptureService.PickedRegion, outputURL: URL, showClicks: Bool, microphone: Bool) async throws {
        self.outputURL = outputURL

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let display = content.displays.first { $0.displayID == region.display.displayID } ?? region.display
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

        // H.264 wants even dimensions.
        let scale = region.pointPixelScale
        let width = Int(region.sourceRect.width * scale) & ~1
        let height = Int(region.sourceRect.height * scale) & ~1

        let config = SCStreamConfiguration()
        config.sourceRect = region.sourceRect
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.queueDepth = 6
        if #available(macOS 15.0, *) {
            config.showMouseClicks = showClicks
            config.captureMicrophone = microphone
        }

        try? FileManager.default.removeItem(at: outputURL)
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(width * height * 6, 2_000_000),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: 60,
            ] as [String: Any],
        ])
        videoInput.expectsMediaDataInRealTime = true
        writer.add(videoInput)

        super.init()

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if #available(macOS 15.0, *), microphone {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000,
            ])
            audio.expectsMediaDataInRealTime = true
            if writer.canAdd(audio) {
                writer.add(audio)
                audioInput = audio
                try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
            }
        }
        self.stream = stream
    }

    func start() async throws {
        guard writer.startWriting() else {
            throw writer.error ?? CaptureService.CaptureUnavailable()
        }
        try await stream?.startCapture()
    }

    /// Stops capture and finalizes the file. Returns nil if no frame arrived.
    func stop() async -> URL? {
        try? await stream?.stopCapture()
        stream = nil
        let endTime = CMClockGetTime(CMClockGetHostTimeClock())
        let started: Bool = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.sessionStarted) }
        }
        guard started else {
            writer.cancelWriting()
            return nil
        }
        // Idle screens deliver no frames; ending the session "now" holds the
        // last frame so the video is as long as the recording was.
        writer.endSession(atSourceTime: endTime)
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed ? outputURL : nil
    }

    func cancel() async {
        try? await stream?.stopCapture()
        stream = nil
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: outputURL)
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, writer.status == .writing else { return }

        if type == .screen {
            // Idle/blank frames carry no pixels — only complete frames go in.
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]],
                  let rawStatus = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: rawStatus) == .complete
            else { return }

            if !sessionStarted {
                writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
                sessionStarted = true
            }
            if videoInput.isReadyForMoreMediaData {
                videoInput.append(sampleBuffer)
            }
            return
        }

        if #available(macOS 15.0, *), type == .microphone,
           sessionStarted, let audioInput, audioInput.isReadyForMoreMediaData {
            audioInput.append(sampleBuffer)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Snipost recording stopped: \(error.localizedDescription)")
    }
}

/// Owns the region-recording flow: pick → border + HUD → stop → file.
@MainActor
final class RecordingController: ObservableObject {
    static let shared = RecordingController()

    @Published private(set) var startedAt: Date?
    var isRecording: Bool { startedAt != nil }

    /// Called with the finished .mp4.
    var onFinished: ((URL) -> Void)?

    private var recorder: ScreenRecorder?
    private var chrome: RegionChrome?

    static var recordingsDirectory: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let dir = movies.appendingPathComponent("Snipost", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func toggle() {
        if isRecording { stop() } else { begin() }
    }

    func begin() {
        guard !isRecording, recorder == nil else { return }
        CaptureService.pickRegion(hint: "Drag an area to record — Esc to cancel") { [weak self] region in
            guard let self, let region else { return }
            Task { @MainActor in await self.start(region) }
        }
    }

    private func start(_ region: CaptureService.PickedRegion) async {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = Self.recordingsDirectory
            .appendingPathComponent("Snipost Recording \(formatter.string(from: Date())).mp4")
        let prefs = Preferences.shared
        do {
            let recorder = try await ScreenRecorder(
                region: region,
                outputURL: url,
                showClicks: prefs.recordCursorClicks,
                microphone: prefs.recordMicrophone
            )
            self.recorder = recorder
            chrome = RegionChrome(region: region.globalRect, tint: .systemRed, dashed: false) { [weak self] in
                RecordingHUD(
                    controller: RecordingController.shared,
                    onStop: { self?.stop() },
                    onCancel: { self?.cancel() }
                )
            }
            try await recorder.start()
            startedAt = Date()
        } catch {
            chrome?.close()
            chrome = nil
            recorder = nil
            Toast.show("Recording failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard let recorder else { return }
        self.recorder = nil
        startedAt = nil
        chrome?.close()
        chrome = nil
        Task { @MainActor in
            if let url = await recorder.stop() {
                onFinished?(url)
            } else {
                Toast.show("Nothing was recorded")
            }
        }
    }

    func cancel() {
        guard let recorder else { return }
        self.recorder = nil
        startedAt = nil
        chrome?.close()
        chrome = nil
        Task { await recorder.cancel() }
        Toast.show("Recording discarded")
    }
}
