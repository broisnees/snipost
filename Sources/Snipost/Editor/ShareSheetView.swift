import SwiftUI

/// Compose-once, post-anywhere sheet. Web platforms open their composer with
/// the image on the clipboard; Bluesky/Mastodon post directly via API.
struct ShareSheetView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject private var accounts = ShareAccounts.shared
    @Environment(\.dismiss) private var dismiss

    @State private var caption = ""
    @State private var busy = false
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Post this capture")
                .font(.headline)

            TextEditor(text: $caption)
                .font(.body)
                .frame(height: 76)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))

            VStack(alignment: .leading, spacing: 6) {
                Text("Open composer — the image attaches automatically")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(WebIntent.allCases) { intent in
                        Button(intent.rawValue) { openIntent(intent) }
                            .frame(maxWidth: .infinity)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Post directly")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("Bluesky") { postBluesky() }
                        .frame(maxWidth: .infinity)
                        .disabled(!accounts.blueskyConfigured || busy)
                    Button("Mastodon") { postMastodon() }
                        .frame(maxWidth: .infinity)
                        .disabled(!accounts.mastodonConfigured || busy)
                }
                if !accounts.blueskyConfigured || !accounts.mastodonConfigured {
                    Text("Add accounts in Settings → Accounts to enable direct posting.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if busy {
                ProgressView()
                    .controlSize(.small)
            }
            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(status.hasPrefix("Posted") ? .green : .red)
                    .lineLimit(3)
            }

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 400)
    }

    private func openIntent(_ intent: WebIntent) {
        Task {
            guard let image = await model.renderFullAsync() else { return }
            ShareService.openWebIntent(intent, caption: caption, image: image)
            status = "Opened \(intent.rawValue) composer — image attaches in a few seconds (⌘V if it's missing)"
        }
    }

    private func postBluesky() {
        busy = true
        status = nil
        let handle = accounts.blueskyHandle
        let password = accounts.blueskyAppPassword
        Task {
            guard let image = await model.renderFullAsync() else { busy = false; return }
            do {
                let link = try await ShareService.postToBluesky(
                    caption: caption, image: image, handle: handle, appPassword: password
                )
                copyLink(link)
                status = "Posted to Bluesky — link copied"
            } catch {
                status = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            busy = false
        }
    }

    private func postMastodon() {
        busy = true
        status = nil
        let instance = accounts.mastodonInstance
        let token = accounts.mastodonToken
        Task {
            guard let image = await model.renderFullAsync() else { busy = false; return }
            do {
                let link = try await ShareService.postToMastodon(
                    caption: caption, image: image, instance: instance, token: token
                )
                copyLink(link)
                status = "Posted to Mastodon — link copied"
            } catch {
                status = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            busy = false
        }
    }

    private func copyLink(_ link: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
    }
}
