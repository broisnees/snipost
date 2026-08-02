import AppKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            AccountsSettingsTab()
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
        }
        .frame(width: 500, height: 480)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        Form {
            Section("Shortcuts") {
                ForEach(HotkeyAction.allCases, id: \.rawValue) { action in
                    HotkeyRow(action: action)
                }
            }

            Section("After capture") {
                Picker("Show", selection: $prefs.captureFlow) {
                    ForEach(CaptureFlow.allCases) { flow in
                        Text(flow.title).tag(flow)
                    }
                }
                Toggle("Copy beautified image to clipboard", isOn: $prefs.autoCopy)
                Toggle("Save every capture automatically", isOn: $prefs.autoSaveToDesktop)
                HStack {
                    Text("Save folder")
                    Spacer()
                    Text(prefs.saveFolderName)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose…") { chooseSaveFolder() }
                        .controlSize(.small)
                    if !prefs.saveFolderPath.isEmpty {
                        Button("Desktop") { prefs.saveFolderPath = "" }
                            .controlSize(.small)
                    }
                }
                Toggle("Keep capture history", isOn: $prefs.saveHistory)
                Toggle("Include the mouse pointer (live position and shape)", isOn: $prefs.includeCursor)
                Text(flowCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseSaveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = prefs.saveFolder
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        prefs.saveFolderPath = url.path
    }

    private var flowCaption: String {
        switch prefs.captureFlow {
        case .editor:
            return "The editor opens after every capture so you can tweak before exporting."
        case .thumbnail:
            return "A floating thumbnail appears bottom-right with quick actions — click it to open the editor."
        case .instant:
            return "Captures are beautified with default settings and copied/saved right away — no UI."
        }
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
            Button(recording ? "Press shortcut… (Esc cancels)" : prefs.hotkey(for: action).display) {
                recording ? stop() : start()
            }
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
        window.styleMask = [.titled, .closable]
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
