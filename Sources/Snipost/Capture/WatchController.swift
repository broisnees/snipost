import AppKit
import SwiftUI

/// "Watch with AI": the user drags a region and (optionally) says what to
/// look for. Snipost samples the region every few seconds, skips frames that
/// didn't change, and asks Claude about the ones that did — notifying when
/// the condition is met.
@MainActor
final class WatchController: ObservableObject {
    static let shared = WatchController()

    enum Phase: Equatable {
        case idle
        case setup
        case watching
        case done
    }

    @Published private(set) var phase: Phase = .idle
    @Published var condition = ""
    @Published private(set) var note: String?
    @Published private(set) var lastChecked: Date?
    @Published private(set) var thinking = false
    @Published private(set) var errorText: String?
    @Published private(set) var checks = 0

    var isActive: Bool { phase != .idle }

    private var region: CaptureService.PickedRegion?
    private var chrome: RegionChrome?
    private var loop: Task<Void, Never>?
    private var lastSignature: [UInt8]?
    private var lastNotified = Date.distantPast
    private var grabber: CaptureService.RegionGrabber?

    func toggle() {
        if isActive { close() } else { begin() }
    }

    func begin() {
        guard phase == .idle else { return }
        CaptureService.pickRegion(hint: "Drag an area for Claude to watch — Esc to cancel") { [weak self] region in
            guard let self, let region else { return }
            self.region = region
            self.reset()
            self.phase = .setup
            self.chrome = RegionChrome(region: region.globalRect, tint: .systemPurple, dashed: true) {
                WatchHUD(controller: WatchController.shared)
            }
            self.chrome?.focusHUD()
        }
    }

    func start() {
        guard phase == .setup || phase == .done else { return }
        let agent = Preferences.shared.watchAgent
        if agent == .api, Preferences.shared.anthropicAPIKey.isEmpty {
            errorText = ClaudeVision.Failure.missingKey.errorDescription
            SettingsWindowController.shared.show()
            return
        }
        if agent != .api, AgentRunner.executable(for: agent) == nil,
           let fallback = AgentRunner.installedAgents().first {
            Preferences.shared.watchAgent = fallback
        } else if agent != .api, AgentRunner.executable(for: agent) == nil {
            errorText = AgentRunner.Failure.notInstalled(agent.title).errorDescription
            SettingsWindowController.shared.show()
            return
        }
        errorText = nil
        phase = .watching
        lastSignature = nil
        Notifier.requestPermissionIfNeeded()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                let interval = Preferences.shared.watchInterval
                try? await Task.sleep(nanoseconds: UInt64(max(interval, 2) * 1_000_000_000))
            }
        }
    }

    func close() {
        loop?.cancel()
        loop = nil
        chrome?.close()
        chrome = nil
        region = nil
        grabber = nil
        phase = .idle
    }

    private func reset() {
        note = nil
        lastChecked = nil
        errorText = nil
        checks = 0
        lastSignature = nil
    }

    private func tick() async {
        guard phase == .watching, let region else { return }
        let image: CGImage
        do {
            if grabber == nil { grabber = try await CaptureService.RegionGrabber(region, maxPixelSize: 1400) }
            image = try await grabber!.grab()
        } catch {
            errorText = "Can't capture the region (Screen Recording permission?)"
            return
        }
        lastChecked = Date()

        let signature = Self.signature(of: image)
        if let lastSignature, !Self.changed(lastSignature, signature) {
            return // nothing moved — don't spend an API call
        }
        lastSignature = signature

        thinking = true
        defer { thinking = false }
        do {
            let trimmed = condition.trimmingCharacters(in: .whitespacesAndNewlines)
            let agent = Preferences.shared.watchAgent
            let observation = agent == .api
                ? try await ClaudeVision.observe(image: image, condition: trimmed, previousNote: note,
                                                 apiKey: Preferences.shared.anthropicAPIKey)
                : try await AgentRunner.observe(agent: agent, image: image, condition: trimmed, previousNote: note)
            guard phase == .watching else { return } // stopped mid-request
            checks += 1
            errorText = nil
            note = observation.summary
            if observation.conditionMet {
                handleHit(observation.summary)
            }
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if case ClaudeVision.Failure.missingKey = error { pause() }
            if case AgentRunner.Failure.notInstalled = error { pause() }
            if let http = error as? HTTPError, http.status == 401 { pause() }
        }
    }

    private func handleHit(_ summary: String) {
        let hasCondition = !condition.trimmingCharacters(in: .whitespaces).isEmpty
        if hasCondition {
            Notifier.notify(title: "Snipost Watch: condition met", body: summary)
            NSSound(named: "Glass")?.play()
            pause()
            phase = .done
        } else if Date().timeIntervalSince(lastNotified) > 20 {
            lastNotified = Date()
            Notifier.notify(title: "Snipost Watch", body: summary)
        }
    }

    private func pause() {
        loop?.cancel()
        loop = nil
        if phase == .watching { phase = .setup }
    }

    // MARK: Change detection

    private static let side = 64

    /// 64×64 grayscale thumbnail — cheap to compare, coarse enough to ignore
    /// sub-pixel noise.
    private static func signature(of image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: side * side)
        pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(
                data: buffer.baseAddress, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        return pixels
    }

    private static func changed(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        var differing = 0
        for i in 0..<min(a.count, b.count) where abs(Int(a[i]) - Int(b[i])) > 14 {
            differing += 1
            if differing >= 3 { return true }
        }
        return false
    }
}

struct WatchHUD: View {
    @ObservedObject var controller: WatchController
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HUDCapsule {
            VStack(alignment: .leading, spacing: 8) {
                header
                switch controller.phase {
                case .setup, .idle:
                    setupRow
                case .watching, .done:
                    statusRows
                }
                if let error = controller.errorText {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 340, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: controller.phase == .done ? "checkmark.seal.fill" : "eye")
                .foregroundStyle(controller.phase == .done ? .green : .purple)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Text(Preferences.shared.watchAgent.title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if controller.thinking {
                ProgressView().controlSize(.mini)
            }
            HUDIconButton(symbol: "xmark", help: "Stop watching") { controller.close() }
        }
    }

    private var title: String {
        switch controller.phase {
        case .idle, .setup: return "Watch with AI"
        case .watching: return "Watching…"
        case .done: return "Condition met"
        }
    }

    private var setupRow: some View {
        HStack(spacing: 6) {
            TextField("What should I watch for? (optional)", text: $controller.condition)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit { controller.start() }
                .onAppear { fieldFocused = true }
            Button("Start") { controller.start() }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
        }
    }

    private var statusRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !controller.condition.isEmpty {
                Text("“\(controller.condition)”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text(controller.note ?? "Waiting for the first look…")
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(footer(at: context.date))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if controller.phase == .done {
                Button("Keep watching") { controller.start() }
                    .controlSize(.small)
            }
        }
    }

    private func footer(at date: Date) -> String {
        var parts = ["\(controller.checks) AI check\(controller.checks == 1 ? "" : "s")"]
        if let last = controller.lastChecked {
            parts.append("sampled \(max(0, Int(date.timeIntervalSince(last))))s ago")
        }
        parts.append("every \(Int(Preferences.shared.watchInterval))s")
        parts.append(Preferences.shared.watchAgent.title)
        return parts.joined(separator: " · ")
    }
}
