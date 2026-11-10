import AppKit
import ApplicationServices
import ScreenCaptureKit
import SwiftUI

extension CaptureService {
    /// Scrolling capture: drag an area, then either let Snipost auto-scroll
    /// (needs Accessibility) or scroll it yourself. Frames are stitched live;
    /// sticky headers/footers are detected and kept once.
    @MainActor
    static func captureScrolling(completion: @escaping @MainActor (CGImage?) -> Void) {
        pickRegion(hint: "Drag over the scrollable area — Esc to cancel") { region in
            guard let region else {
                completion(nil)
                return
            }
            ScrollingCaptureSession(region: region, completion: completion).start()
        }
    }
}

@MainActor
final class ScrollingCaptureSession: ObservableObject {
    private static var current: ScrollingCaptureSession?

    @Published private(set) var frameCount = 0
    @Published private(set) var totalHeight = 0
    @Published private(set) var preview: NSImage?
    @Published private(set) var autoScrolling = false
    @Published private(set) var status = "Starting…"
    let canAutoScroll = AXIsProcessTrusted()

    private let region: CaptureService.PickedRegion
    private let completion: @MainActor (CGImage?) -> Void
    private var chrome: RegionChrome?
    private var loop: Task<Void, Never>?
    private var finished = false
    private var grabber: CaptureService.RegionGrabber?

    // Stitch state
    private var stitch = Stitcher.Session()
    private var previewSlices: [CGImage] = []

    init(region: CaptureService.PickedRegion, completion: @escaping @MainActor (CGImage?) -> Void) {
        self.region = region
        self.completion = completion
    }

    func start() {
        Self.current?.cancel()
        Self.current = self
        chrome = RegionChrome(region: region.globalRect, tint: .systemBlue, dashed: true) {
            ScrollingHUD(session: self)
        }
        autoScrolling = canAutoScroll
        loop = Task { [weak self] in await self?.run() }
    }

    func toggleAutoScroll() {
        guard canAutoScroll else { return }
        autoScrolling.toggle()
    }

    func done() { finish(cancelled: false) }
    func cancel() { finish(cancelled: true) }

    // MARK: Loop

    private func run() async {
        if autoScrolling {
            CGWarpMouseCursorPosition(scrollLocation())
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        guard let first = await grab() else {
            status = "Can't capture this area"
            return
        }
        await accept(first)

        var stalls = 0
        while !Task.isCancelled, !finished {
            if autoScrolling {
                await postScroll()
                guard let frame = await settledFrame() else { break }
                let added = await accept(frame)
                if added == 0 {
                    stalls += 1
                    status = "Checking for more…"
                    if stalls >= 3 { // bottom reached (allows one lazy-load pause)
                        finish(cancelled: false)
                        return
                    }
                } else {
                    stalls = 0
                }
            } else {
                // Manual: sample while the user scrolls.
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard let frame = await grab() else { continue }
                await accept(frame)
            }
        }
    }

    /// Stitches a frame in; returns how many new rows it contributed.
    @discardableResult
    private func accept(_ frame: CGImage) async -> Int {
        let session = stitch
        let (updated, result) = await Task.detached(priority: .userInitiated) {
            var copy = session
            let result = copy.add(frame)
            return (copy, result)
        }.value
        guard !finished else { return 0 }
        stitch = updated

        switch result {
        case .first, .added:
            frameCount = stitch.segmentCount
            totalHeight = stitch.totalHeight
            if case .added(let rows) = result {
                status = autoScrolling ? "Scrolling…" : "Keep scrolling — click Done at the end"
                appendPreview(from: frame, rows: rows)
                if totalHeight > 30_000 { finish(cancelled: false) } // sanity cap
                return rows
            }
            status = autoScrolling ? "Scrolling…" : "Scroll the page, then click Done"
            appendPreview(from: frame, rows: nil)
            return frame.height
        case .unchanged:
            return 0
        case .lost:
            status = "Scrolled too far — scroll back up a little"
            return 0
        }
    }

    private func grab() async -> CGImage? {
        if grabber == nil { grabber = try? await CaptureService.RegionGrabber(region) }
        return try? await grabber?.grab()
    }

    /// After a scroll, wait until two consecutive frames match (smooth
    /// scrolling and lazy rendering finished), capped at ~1 s.
    private func settledFrame() async -> CGImage? {
        var last = await grab()
        for _ in 0..<8 {
            try? await Task.sleep(nanoseconds: 110_000_000)
            guard let next = await grab() else { return last }
            if let previous = last, Stitcher.quickEqual(previous, next) { return next }
            last = next
        }
        return last
    }

    private func postScroll() async {
        let location = scrollLocation()
        // A few small wheel events instead of one big one: apps with scroll
        // acceleration or smoothing move a predictable distance.
        let total = max(40, region.viewRect.height * 0.45)
        let steps = 4
        for _ in 0..<steps {
            guard let event = CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                wheel1: -Int32(total / CGFloat(steps)), wheel2: 0, wheel3: 0
            ) else { return }
            event.location = location
            event.post(tap: .cghidEventTap)
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
    }

    /// Center of the region in CG global coordinates (top-left origin).
    private func scrollLocation() -> CGPoint {
        let rect = region.globalRect
        let primaryHeight = NSScreen.screens.first?.frame.height ?? rect.maxY
        return CGPoint(x: rect.midX, y: primaryHeight - rect.midY)
    }

    // MARK: Preview

    private static let previewWidth = 132

    private func appendPreview(from frame: CGImage, rows: Int?) {
        let slice: CGImage?
        if let rows {
            let band = stitch.movingBand(height: frame.height)
            slice = frame.cropping(to: CGRect(x: 0, y: band.upperBound - rows, width: frame.width, height: rows))
        } else {
            slice = frame
        }
        guard let slice, let small = Stitcher.scaled(slice, toWidth: Self.previewWidth) else { return }
        previewSlices.append(small)
        if let stacked = Stitcher.stack(previewSlices) {
            preview = NSImage(cgImage: stacked, size: NSSize(width: stacked.width, height: stacked.height))
        }
    }

    // MARK: Finish

    private func finish(cancelled: Bool) {
        guard !finished else { return }
        finished = true
        loop?.cancel()
        loop = nil
        chrome?.close()
        chrome = nil
        if Self.current === self { Self.current = nil }

        guard !cancelled else {
            completion(nil)
            return
        }
        if stitch.segmentCount <= 1 {
            Toast.show(canAutoScroll
                ? "The page didn't scroll — try scrolling it yourself"
                : "Nothing scrolled — scroll the page during capture")
        }
        let session = stitch
        Task { @MainActor in
            let image = await Task.detached(priority: .userInitiated) { session.render() }.value
            completion(image)
        }
    }
}

private struct ScrollingHUD: View {
    @ObservedObject var session: ScrollingCaptureSession

    var body: some View {
        HUDCapsule {
            HStack(alignment: .top, spacing: 12) {
                previewStrip
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.and.down.text.horizontal").foregroundStyle(.blue)
                        Text("Scrolling capture").font(.system(size: 12, weight: .semibold))
                    }
                    Text(session.status)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(session.frameCount) frames · \(session.totalHeight) px")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.tertiary)

                    HStack(spacing: 6) {
                        if session.canAutoScroll {
                            Button(session.autoScrolling ? "Pause" : "Auto-scroll") { session.toggleAutoScroll() }
                        }
                        Button("Done") { session.done() }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                        Button("Cancel") { session.cancel() }
                            .keyboardShortcut(.cancelAction)
                    }
                    .controlSize(.small)

                    if !session.canAutoScroll {
                        Text("Grant Accessibility in Settings to auto-scroll.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 210, alignment: .leading)
            }
        }
    }

    private var previewStrip: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06))
            if let preview = session.preview {
                // Pin to the newest content, like a growing receipt.
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 66, alignment: .bottom)
                    .frame(width: 66, height: 120, alignment: .bottom)
                    .clipped()
            }
        }
        .frame(width: 66, height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
    }
}

/// Frame stitching on row fingerprints (FNV hash of sampled pixels in the
/// middle columns, skipping edges and overlay scrollbars).
///
/// - Uniform rows (blank margins) never count as evidence — they match at any
///   offset and used to cause duplicated or skipped content.
/// - Rows that stay put between frames at the top/bottom are a sticky header
///   or footer: kept once, excluded from matching and slicing.
enum Stitcher {
    struct Signature: Sendable {
        let hashes: [UInt64]
        let flat: [Bool]
    }

    enum AddResult {
        case first
        case added(Int)
        case unchanged
        case lost
    }

    struct Session: @unchecked Sendable {
        private(set) var segments: [CGImage] = []
        private var lastFrame: CGImage?
        private var lastSignature: Signature?
        private var header = 0
        private var footer = 0
        private var bandsLocked = false

        var segmentCount: Int { segments.count }
        var totalHeight: Int {
            segments.reduce(0) { $0 + $1.height } + footer
        }

        func movingBand(height: Int) -> Range<Int> { header..<(height - footer) }

        mutating func add(_ frame: CGImage) -> AddResult {
            guard let signature = Stitcher.signature(frame) else { return .unchanged }
            guard let previousFrame = lastFrame, let previous = lastSignature,
                  previousFrame.width == frame.width, previousFrame.height == frame.height
            else {
                segments = [frame]
                lastFrame = frame
                lastSignature = signature
                return .first
            }
            if previous.hashes == signature.hashes { return .unchanged }

            if !bandsLocked {
                let bands = Stitcher.staticBands(previous, signature)
                header = bands.top
                footer = bands.bottom
            }
            let band = movingBand(height: frame.height)
            guard band.count > 40 else { return .unchanged }

            guard let shift = Stitcher.offset(previous, signature, band: band) else { return .lost }
            if shift == 0 { return .unchanged }

            if !bandsLocked {
                bandsLocked = true
                // The first segment keeps the header; trim its footer (the
                // footer is appended once at the very end).
                if footer > 0, let first = segments.first,
                   let trimmed = first.cropping(to: CGRect(x: 0, y: 0, width: first.width, height: first.height - footer)) {
                    segments[0] = trimmed
                }
            }
            guard let slice = frame.cropping(to: CGRect(
                x: 0, y: band.upperBound - shift, width: frame.width, height: shift
            )) else { return .unchanged }
            segments.append(slice)
            lastFrame = frame
            lastSignature = signature
            return .added(shift)
        }

        func render() -> CGImage? {
            var parts = segments
            if footer > 0, let last = lastFrame,
               let footerSlice = last.cropping(to: CGRect(x: 0, y: last.height - footer, width: last.width, height: footer)) {
                parts.append(footerSlice)
            }
            return Stitcher.stack(parts)
        }
    }

    // MARK: Matching

    /// Leading/trailing rows identical in both frames, capped at 30% each.
    static func staticBands(_ a: Signature, _ b: Signature) -> (top: Int, bottom: Int) {
        let height = a.hashes.count
        let cap = height * 3 / 10
        var top = 0
        while top < cap, a.hashes[top] == b.hashes[top] { top += 1 }
        var bottom = 0
        while bottom < cap, a.hashes[height - 1 - bottom] == b.hashes[height - 1 - bottom] { bottom += 1 }
        // A band of only blank rows isn't a sticky bar — it's page background.
        if (0..<top).allSatisfy({ a.flat[$0] }) { top = 0 }
        if (0..<bottom).allSatisfy({ a.flat[height - 1 - $0] }) { bottom = 0 }
        return (top, bottom)
    }

    /// Content shift (rows moved up) within `band`, scored only on
    /// informative rows. nil = frames differ but no shift explains it.
    static func offset(_ previous: Signature, _ next: Signature, band: Range<Int>) -> Int? {
        let length = band.count
        let minOverlap = max(24, length / 6)
        guard length > minOverlap + 2 else { return nil }

        // Already aligned (only something non-scrolling changed)?
        if score(previous, next, band: band, shift: 0).ratio >= 0.97 { return 0 }

        var best: (shift: Int, ratio: Double, samples: Int)?
        for shift in 1...(length - minOverlap) {
            let result = score(previous, next, band: band, shift: shift)
            guard result.samples >= 12, result.ratio >= 0.92 else { continue }
            if best == nil || result.ratio > best!.ratio + 0.001
                || (abs(result.ratio - best!.ratio) <= 0.001 && result.samples > best!.samples) {
                best = (shift, result.ratio, result.samples)
            }
            if result.ratio >= 0.999, result.samples >= 40 { break } // exact match, stop early
        }
        return best?.shift
    }

    /// next[i] should equal previous[i + shift] for rows inside the band.
    private static func score(_ previous: Signature, _ next: Signature, band: Range<Int>, shift: Int) -> (ratio: Double, samples: Int) {
        var matches = 0
        var samples = 0
        var i = band.lowerBound
        let end = band.upperBound - shift
        while i < end {
            let j = i + shift
            if !previous.flat[j] {
                samples += 1
                if next.hashes[i] == previous.hashes[j] { matches += 1 }
            }
            i += 2
        }
        return (samples == 0 ? 0 : Double(matches) / Double(samples), samples)
    }

    static func quickEqual(_ a: CGImage, _ b: CGImage) -> Bool {
        guard a.width == b.width, a.height == b.height,
              let sa = signature(a, columnStep: 16), let sb = signature(b, columnStep: 16) else { return false }
        return sa.hashes == sb.hashes
    }

    // MARK: Pixels

    static func signature(_ image: CGImage, columnStep: Int = 4) -> Signature? {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn: Bool = data.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        let x0 = max(4, Int(Double(width) * 0.06))
        let x1 = min(width - 4, Int(Double(width) * 0.88))
        guard x1 > x0 + 16 else { return nil }

        var hashes = [UInt64](repeating: 0, count: height)
        var flat = [Bool](repeating: true, count: height)
        data.withUnsafeBufferPointer { pixels in
            for y in 0..<height {
                let row = y * bytesPerRow
                var hash: UInt64 = 0xcbf2_9ce4_8422_2325
                let r0 = pixels[row + x0 * 4], g0 = pixels[row + x0 * 4 + 1], b0 = pixels[row + x0 * 4 + 2]
                var uniform = true
                var x = x0
                while x < x1 {
                    let i = row + x * 4
                    let r = pixels[i], g = pixels[i + 1], b = pixels[i + 2]
                    hash = (hash ^ UInt64(r)) &* 0x0000_0100_0000_01b3
                    hash = (hash ^ UInt64(g)) &* 0x0000_0100_0000_01b3
                    hash = (hash ^ UInt64(b)) &* 0x0000_0100_0000_01b3
                    if uniform, r != r0 || g != g0 || b != b0 { uniform = false }
                    x += columnStep
                }
                hashes[y] = hash
                flat[y] = uniform
            }
        }
        return Signature(hashes: hashes, flat: flat)
    }

    static func stack(_ segments: [CGImage]) -> CGImage? {
        guard let first = segments.first else { return nil }
        guard segments.count > 1 else { return first }
        let width = first.width
        let totalHeight = segments.reduce(0) { $0 + $1.height }
        guard totalHeight > 0,
              let ctx = CGContext(
                data: nil, width: width, height: totalHeight,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: first.colorSpace ?? CGColorSpaceCreateDeviceRGB(), // keep Display P3 etc.
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return first }

        var yFromTop = 0
        for segment in segments {
            ctx.draw(segment, in: CGRect(
                x: 0, y: totalHeight - yFromTop - segment.height,
                width: width, height: segment.height
            ))
            yFromTop += segment.height
        }
        return ctx.makeImage()
    }

    static func scaled(_ image: CGImage, toWidth width: Int) -> CGImage? {
        let height = max(1, Int(Double(image.height) * Double(width) / Double(max(image.width, 1))))
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}
