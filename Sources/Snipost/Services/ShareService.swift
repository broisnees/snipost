import AppKit
import ApplicationServices
import Foundation

/// Credentials for direct-API posting, persisted in UserDefaults + Keychain.
@MainActor
final class ShareAccounts: ObservableObject {
    static let shared = ShareAccounts()

    @Published var blueskyHandle: String {
        didSet { UserDefaults.standard.set(blueskyHandle, forKey: "bluesky.handle") }
    }
    @Published var blueskyAppPassword: String {
        didSet { Keychain.set(blueskyAppPassword, for: "bluesky.appPassword") }
    }
    @Published var mastodonInstance: String {
        didSet { UserDefaults.standard.set(mastodonInstance, forKey: "mastodon.instance") }
    }
    @Published var mastodonToken: String {
        didSet { Keychain.set(mastodonToken, for: "mastodon.token") }
    }

    private init() {
        blueskyHandle = UserDefaults.standard.string(forKey: "bluesky.handle") ?? ""
        blueskyAppPassword = Keychain.get("bluesky.appPassword") ?? ""
        mastodonInstance = UserDefaults.standard.string(forKey: "mastodon.instance") ?? ""
        mastodonToken = Keychain.get("mastodon.token") ?? ""
    }

    var blueskyConfigured: Bool { !blueskyHandle.isEmpty && !blueskyAppPassword.isEmpty }
    var mastodonConfigured: Bool { !mastodonInstance.isEmpty && !mastodonToken.isEmpty }
}

enum WebIntent: String, CaseIterable, Identifiable {
    case x = "X"
    case threads = "Threads"
    case linkedin = "LinkedIn"

    var id: String { rawValue }

    func composeURL(text: String) -> URL? {
        var components: URLComponents
        switch self {
        case .x:
            components = URLComponents(string: "https://twitter.com/intent/tweet")!
            components.queryItems = [URLQueryItem(name: "text", value: text)]
        case .threads:
            components = URLComponents(string: "https://www.threads.net/intent/post")!
            components.queryItems = [URLQueryItem(name: "text", value: text)]
        case .linkedin:
            components = URLComponents(string: "https://www.linkedin.com/feed/")!
            components.queryItems = [
                URLQueryItem(name: "shareActive", value: "true"),
                URLQueryItem(name: "text", value: text),
            ]
        }
        return components.url
    }
}

enum ShareError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return nil
    }
}

enum ShareService {
    /// Copies the image, opens the platform's web composer, and — when
    /// Accessibility is granted — auto-pastes so the image actually attaches.
    /// (Web intents carry text only; there is no URL parameter for images.)
    @MainActor
    static func openWebIntent(_ intent: WebIntent, caption: String, image: CGImage) {
        Clipboard.copy(image)
        guard let url = intent.composeURL(text: caption) else { return }
        let browser = NSWorkspace.shared.urlForApplication(toOpen: url)
        NSWorkspace.shared.open(url)

        if AXIsProcessTrusted() {
            Toast.show("Opening \(intent.rawValue) — attaching the image…")
            Task { @MainActor in
                // Give the browser time to load and focus the composer.
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                // Never paste into whatever else the user switched to.
                guard let browser,
                      NSWorkspace.shared.frontmostApplication?.bundleURL?.standardizedFileURL == browser.standardizedFileURL
                else {
                    Toast.show("Image copied — click the composer and press ⌘V")
                    return
                }
                postPasteKeystroke()
                Toast.show("Image attached — review and post (⌘V if it's missing)")
            }
        } else {
            Toast.show("Image copied — click the composer and press ⌘V to attach")
        }
    }

    /// Synthetic ⌘V into the frontmost app (the browser's compose box).
    @MainActor
    private static func postPasteKeystroke() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey = CGKeyCode(9) // kVK_ANSI_V
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // MARK: Bluesky (AT Protocol)

    static func postToBluesky(caption: String, image: CGImage, handle: String, appPassword: String) async throws -> String {
        // 1. Session
        var session = URLRequest(url: URL(string: "https://bsky.social/xrpc/com.atproto.server.createSession")!)
        session.httpMethod = "POST"
        session.setValue("application/json", forHTTPHeaderField: "Content-Type")
        session.httpBody = try JSONSerialization.data(withJSONObject: [
            "identifier": handle,
            "password": appPassword,
        ])
        let (sessionData, sessionResponse) = try await URLSession.shared.data(for: session)
        try Net.check(sessionResponse, sessionData)
        guard let sessionJSON = try JSONSerialization.jsonObject(with: sessionData) as? [String: Any],
              let jwt = sessionJSON["accessJwt"] as? String,
              let did = sessionJSON["did"] as? String
        else { throw ShareError.message("Bluesky sign-in failed") }

        // 2. Upload the image blob (hard 1 MB limit)
        guard let jpeg = ImageEncoding.jpegData(image, maxBytes: 950_000) else {
            throw ShareError.message("Could not compress the image under Bluesky's 1 MB limit")
        }
        var upload = URLRequest(url: URL(string: "https://bsky.social/xrpc/com.atproto.repo.uploadBlob")!)
        upload.httpMethod = "POST"
        upload.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        upload.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        upload.httpBody = jpeg
        let (blobData, blobResponse) = try await URLSession.shared.data(for: upload)
        try Net.check(blobResponse, blobData)
        guard let blobJSON = try JSONSerialization.jsonObject(with: blobData) as? [String: Any],
              let blob = blobJSON["blob"]
        else { throw ShareError.message("Bluesky blob upload failed") }

        // 3. Create the post
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let record: [String: Any] = [
            "$type": "app.bsky.feed.post",
            "text": caption,
            "createdAt": iso.string(from: Date()),
            "embed": [
                "$type": "app.bsky.embed.images",
                "images": [["alt": "Screenshot", "image": blob]],
            ],
        ]
        var post = URLRequest(url: URL(string: "https://bsky.social/xrpc/com.atproto.repo.createRecord")!)
        post.httpMethod = "POST"
        post.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        post.httpBody = try JSONSerialization.data(withJSONObject: [
            "repo": did,
            "collection": "app.bsky.feed.post",
            "record": record,
        ])
        let (postData, postResponse) = try await URLSession.shared.data(for: post)
        try Net.check(postResponse, postData)
        guard let postJSON = try JSONSerialization.jsonObject(with: postData) as? [String: Any],
              let uri = postJSON["uri"] as? String,
              let rkey = uri.components(separatedBy: "/").last
        else { throw ShareError.message("Bluesky post failed") }

        return "https://bsky.app/profile/\(handle)/post/\(rkey)"
    }

    // MARK: Mastodon

    static func postToMastodon(caption: String, image: CGImage, instance: String, token: String) async throws -> String {
        let host = instance
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let base = URL(string: "https://\(host)") else {
            throw ShareError.message("Invalid Mastodon instance")
        }
        guard let png = ImageEncoding.pngData(image) else {
            throw ShareError.message("Could not encode PNG")
        }

        // 1. Upload media
        let boundary = "snipost-\(UUID().uuidString)"
        var body = Data()
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"snipost.png\"\r\n")
        body.appendString("Content-Type: image/png\r\n\r\n")
        body.append(png)
        body.appendString("\r\n--\(boundary)--\r\n")

        var upload = URLRequest(url: base.appendingPathComponent("api/v2/media"))
        upload.httpMethod = "POST"
        upload.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        upload.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        upload.httpBody = body
        let (mediaData, mediaResponse) = try await URLSession.shared.data(for: upload)
        try Net.check(mediaResponse, mediaData)
        guard let mediaJSON = try JSONSerialization.jsonObject(with: mediaData) as? [String: Any],
              let mediaID = (mediaJSON["id"] as? String) ?? (mediaJSON["id"] as? Int).map(String.init)
        else { throw ShareError.message("Mastodon media upload failed") }

        // 2. Wait for processing if the server returned 202
        if (mediaResponse as? HTTPURLResponse)?.statusCode == 202 {
            for _ in 0..<12 {
                try await Task.sleep(nanoseconds: 600_000_000)
                var poll = URLRequest(url: base.appendingPathComponent("api/v1/media/\(mediaID)"))
                poll.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                let (pollData, pollResponse) = try await URLSession.shared.data(for: poll)
                if (pollResponse as? HTTPURLResponse)?.statusCode == 200,
                   let pollJSON = try JSONSerialization.jsonObject(with: pollData) as? [String: Any],
                   pollJSON["url"] is String {
                    break
                }
            }
        }

        // 3. Publish the status
        var status = URLRequest(url: base.appendingPathComponent("api/v1/statuses"))
        status.httpMethod = "POST"
        status.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        status.setValue("application/json", forHTTPHeaderField: "Content-Type")
        status.httpBody = try JSONSerialization.data(withJSONObject: [
            "status": caption,
            "media_ids": [mediaID],
        ])
        let (statusData, statusResponse) = try await URLSession.shared.data(for: status)
        try Net.check(statusResponse, statusData)
        guard let statusJSON = try JSONSerialization.jsonObject(with: statusData) as? [String: Any],
              let url = statusJSON["url"] as? String
        else { throw ShareError.message("Mastodon post failed") }
        return url
    }
}
