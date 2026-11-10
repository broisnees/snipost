import AppKit
import ApplicationServices
import SwiftUI

/// System Settings–style window: sidebar of panes, grouped forms on the right.
struct SettingsView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case general, capture, shortcuts, recording, ai, accounts
        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return "General"
            case .capture: return "Capture"
            case .shortcuts: return "Shortcuts"
            case .recording: return "Recording"
            case .ai: return "AI Watch"
            case .accounts: return "Accounts"
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape.fill"
            case .capture: return "camera.viewfinder"
            case .shortcuts: return "command"
            case .recording: return "record.circle.fill"
            case .ai: return "eye.fill"
            case .accounts: return "person.crop.circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .general: return .gray
            case .capture: return .blue
            case .shortcuts: return .indigo
            case .recording: return .red
            case .ai: return .purple
            case .accounts: return .green
            }
        }
    }

    @State private var pane: Pane = .general

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { item in
                Label {
                    Text(item.title)
                } icon: {
                    Image(systemName: item.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(item.tint.gradient))
                }
                .tag(item)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(190)
            .safeAreaInset(edge: .top) {
                HStack(spacing: 10) {
                    BrandTile(size: 30)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Snipost").font(.system(size: 13, weight: .semibold))
                        Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        } detail: {
            Group {
                switch pane {
                case .general: GeneralPane()
                case .capture: CapturePane()
                case .shortcuts: ShortcutsPane()
                case .recording: RecordingPane()
                case .ai: AISettingsTab()
                case .accounts: AccountsSettingsTab()
                }
            }
            .navigationTitle(pane.title)
        }
        .frame(width: 780, height: 560)
    }
}

/// Section footnote styling shared by every pane.
private struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject private var prefs = Preferences.shared
    @State private var launchAtLogin = false
    @State private var screenGranted = CGPreflightScreenCaptureAccess()
    @State private var axGranted = AXIsProcessTrusted()
    private let poll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { prefs.replaceSystemScreenshots }, set: setDefaultApp)) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Default screenshot app")
                        Footnote("⌘⇧3 screen · ⌘⇧4 area · add ⌃ to copy instead · ⌘⇧5 opens the capture bar (screenshots + recording). They're handed back when Snipost quits.")
                    }
                }
                Toggle("Open Snipost at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { LoginItem.set($0); launchAtLogin = LoginItem.isEnabled }
                ))
                .disabled(!LoginItem.isAvailable)
            }

            Section("Permissions") {
                PermissionRow(
                    title: "Screen Recording",
                    detail: "Needed for every capture and recording.",
                    granted: screenGranted
                ) {
                    CGRequestScreenCaptureAccess()
                    open("Privacy_ScreenCapture")
                }
                PermissionRow(
                    title: "Accessibility",
                    detail: "Lets shortcuts fire while menus are open.",
                    granted: axGranted
                ) {
                    AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                    open("Privacy_Accessibility")
                }
                Footnote("After turning Screen Recording on, quit and reopen Snipost — macOS applies it on relaunch.")
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = LoginItem.isEnabled }
        .onReceive(poll) { _ in
            screenGranted = CGPreflightScreenCaptureAccess()
            axGranted = AXIsProcessTrusted()
        }
    }

    private func open(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func setDefaultApp(_ enabled: Bool) {
        guard SystemShortcuts.setSystemShortcutsEnabled(!enabled) else {
            NSSound.beep()
            SystemShortcuts.openKeyboardShortcutsSettings()
            return
        }
        prefs.replaceSystemScreenshots = enabled
        NotificationCenter.default.post(name: .snipostHotkeysChanged, object: nil)
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let fix: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Footnote(detail)
            }
            Spacer()
            if granted {
                Text("Granted").font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Grant…", action: fix).controlSize(.small)
            }
        }
    }
}

// MARK: - Capture

private struct CapturePane: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        Form {
            Section {
                Picker("After capture", selection: $prefs.captureFlow) {
                    ForEach(CaptureFlow.allCases) { flow in
                        Text(flow.title).tag(flow)
                    }
                }
                .pickerStyle(.segmented)
                Footnote(flowCaption)
            }

            Section("Clipboard & files") {
                Toggle("Copy to clipboard automatically", isOn: $prefs.autoCopy)
                Toggle("Style captures automatically (background, padding, shadow)", isOn: $prefs.beautifyByDefault)
                Toggle("Save to Desktop automatically", isOn: $prefs.autoSaveToDesktop)
                Footnote("Off: you get the plain full-resolution screenshot; click Edit on the card to style it. The clipboard holds the PNG and the file together — it pastes as an image in chats and docs, and as a .png file in Finder or upload fields.")
            }

            Section {
                Footnote("While selecting: Space switches to window capture · Return recalls your last area · arrows nudge it, ⇧ arrows resize, ⌥ moves 10 pt · Return captures.")
            }

            Section("Capture") {
                Picker("Self-timer", selection: $prefs.captureDelay) {
                    Text("Off").tag(0)
                    Text("3 seconds").tag(3)
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                }
                Toggle("Include the mouse pointer", isOn: $prefs.includeCursor)
                Toggle("Keep capture history", isOn: $prefs.saveHistory)
            }
        }
        .formStyle(.grouped)
    }

    private var flowCaption: String {
        switch prefs.captureFlow {
        case .editor:
            return "The editor opens after every capture so you can tweak before exporting."
        case .thumbnail:
            return "A floating card appears bottom-right: drag it into any app, click or press Space to Quick Look."
        case .instant:
            return "The screenshot goes straight to the clipboard with a small “Copied” toast. Edit any capture later from the menu bar’s Recent strip or History."
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutsPane: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        Form {
            Section {
                ForEach(HotkeyAction.allCases, id: \.rawValue) { action in
                    HotkeyRow(action: action)
                }
            } footer: {
                Footnote("Click a shortcut, then press the new combination (needs ⌘, ⌥ or ⌃). Esc cancels.")
            }

            if prefs.replaceSystemScreenshots {
                Section("System shortcuts (Snipost is the default)") {
                    ForEach(Array(Preferences.systemHotkeys.enumerated()), id: \.offset) { _, entry in
                        HStack {
                            Text(entry.1.title)
                            Spacer()
                            Text(entry.0.display)
                                .font(.system(.body, design: .rounded).monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Recording

private struct RecordingPane: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        Form {
            Section {
                Toggle("Copy recording to clipboard when it stops", isOn: $prefs.autoCopyRecordings)
                Toggle("Highlight mouse clicks", isOn: $prefs.recordCursorClicks)
                Toggle("Record microphone", isOn: $prefs.recordMicrophone)
            } footer: {
                Footnote("Click highlights and microphone need macOS 15. Click the timer in the menu bar to stop.")
            }

            Section("Saved to") {
                HStack {
                    Image(systemName: "folder.fill").foregroundStyle(.blue)
                    Text(RecordingController.recordingsDirectory.path
                        .replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Show in Finder") {
                        NSWorkspace.shared.open(RecordingController.recordingsDirectory)
                    }
                    .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct HotkeyRow: View {
    let action: HotkeyAction

    @ObservedObject private var prefs = Preferences.shared
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text(action.title)
            Spacer()
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? "Press keys…" : prefs.hotkey(for: action).display)
                    .font(.system(.body, design: .rounded).monospaced())
                    .frame(minWidth: 80)
            }
            .tint(recording ? .accentColor : nil)
        }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Esc
                stop()
                return nil
            }
            if let hotkey = Hotkey(event: event) {
                Preferences.shared.setHotkey(hotkey, for: action)
                stop()
            } else {
                NSSound.beep() // needs ⌘, ⌥, or ⌃
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: - AI

private struct AISettingsTab: View {
    @ObservedObject private var prefs = Preferences.shared
    @State private var key = ""
    @State private var installed: [WatchAgent] = []

    var body: some View {
        Form {
            Section {
                ForEach(WatchAgent.allCases) { agent in
                    agentRow(agent)
                }
            } header: {
                Text("Agent")
            } footer: {
                Footnote("Snipost uses an agent you already have installed and signed in — no extra keys. It runs read-only: the agent can look at the screenshot but can't run commands or edit files. The agent's model must support images.")
            }

            if prefs.watchAgent == .api {
                Section("Anthropic API key") {
                    SecureField("sk-ant-…", text: $key)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { prefs.anthropicAPIKey = key }
                    HStack {
                        Button("Save key") { prefs.anthropicAPIKey = key }
                            .disabled(key == prefs.anthropicAPIKey)
                        if !prefs.anthropicAPIKey.isEmpty {
                            Label("Saved in Keychain", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        }
                    }
                }
            }

            Section("Watching") {
                Picker("Check the region every", selection: $prefs.watchInterval) {
                    Text("2 seconds").tag(2.0)
                    Text("5 seconds").tag(5.0)
                    Text("10 seconds").tag(10.0)
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                }
                Footnote("The agent is only asked when the region's pixels change. Agents take 5–30 s per look, so fast intervals mostly skip unchanged frames.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            key = prefs.anthropicAPIKey
            installed = AgentRunner.installedAgents()
        }
    }

    private func agentRow(_ agent: WatchAgent) -> some View {
        let available = agent == .api || installed.contains(agent)
        return Button {
            prefs.watchAgent = agent
        } label: {
            HStack(spacing: 10) {
                Image(systemName: prefs.watchAgent == agent ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(prefs.watchAgent == agent ? Color.accentColor : .secondary)
                Text(agent.title)
                    .foregroundStyle(available ? .primary : .secondary)
                Spacer()
                if agent == .api {
                    Text("needs key").font(.caption).foregroundStyle(.secondary)
                } else if available {
                    Text(AgentRunner.executable(for: agent)?.path
                        .replacingOccurrences(of: NSHomeDirectory(), with: "~") ?? "")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                } else {
                    Text("not installed").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!available)
    }
}

// MARK: - Accounts

private struct AccountsSettingsTab: View {
    @ObservedObject private var drive = DriveService.shared
    @ObservedObject private var accounts = ShareAccounts.shared
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        Form {
            Section("Google Drive") {
                if drive.isConnected {
                    HStack {
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        Button("Disconnect") { drive.disconnect() }
                    }
                    Toggle("Upload every capture automatically", isOn: $prefs.autoUploadToDrive)
                    Toggle("Notify after each upload", isOn: $prefs.notifyOnDriveUpload)
                    Text("Snips upload into a “Snipost” folder in your Drive (created on the first upload). The Drive button also copies a share link.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    // Developer fallback: only shown while the app ships
                    // without its own embedded OAuth client.
                    if !drive.hasEmbeddedClient {
                        TextField("OAuth Client ID", text: $drive.clientID)
                            .textFieldStyle(.roundedBorder)
                        SecureField("OAuth Client Secret", text: $drive.clientSecret)
                            .textFieldStyle(.roundedBorder)
                        Text("One-time developer setup: create a free OAuth client at console.cloud.google.com → APIs & Services → Credentials → OAuth client ID → Desktop app (enable the Google Drive API), then put it in Resources/DriveClient.plist so users only ever see the Connect button.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Button {
                            drive.connect()
                        } label: {
                            Label(
                                drive.isConnecting ? "Waiting for browser…" : "Connect Google Drive",
                                systemImage: "person.crop.circle.badge.checkmark"
                            )
                        }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                        .disabled(!drive.isConfigured || drive.isConnecting)
                        if drive.isConnecting {
                            ProgressView().controlSize(.small)
                        }
                    }
                    Text("Sign in with your Google account — everything you snip can then sync to a “Snipost” folder in your Drive. Snipost can only see files it creates (drive.file scope).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let error = drive.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            Section("Bluesky") {
                TextField("Handle (e.g. you.bsky.social)", text: $accounts.blueskyHandle)
                    .textFieldStyle(.roundedBorder)
                SecureField("App password", text: $accounts.blueskyAppPassword)
                    .textFieldStyle(.roundedBorder)
                Text("Create an app password in Bluesky → Settings → Privacy and Security → App Passwords.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("Mastodon") {
                TextField("Instance (e.g. mastodon.social)", text: $accounts.mastodonInstance)
                    .textFieldStyle(.roundedBorder)
                SecureField("Access token", text: $accounts.mastodonToken)
                    .textFieldStyle(.roundedBorder)
                Text("Create a token in your instance → Preferences → Development → New application (write scope).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController.make()

    private static func make() -> SettingsWindowController {
        let hosting = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "Snipost Settings"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        return SettingsWindowController(window: window)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
