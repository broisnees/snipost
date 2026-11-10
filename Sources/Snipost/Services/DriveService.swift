import AppKit
import CryptoKit
import Network

/// Google Drive sync using the non-sensitive `drive.file` scope: Snipost can
/// only touch files it creates. OAuth runs through the standard installed-app
/// flow — PKCE plus a localhost loopback redirect — with the user's own
/// OAuth client (created free at console.cloud.google.com).
@MainActor
final class DriveService: ObservableObject {
    static let shared = DriveService()

    @Published var clientID: String {
        didSet { defaults.set(clientID, forKey: "drive.clientID") }
    }
    @Published var clientSecret: String {
        didSet { Keychain.set(clientSecret, for: "drive.clientSecret") }
    }
    /// Mirrored in UserDefaults so checking it never touches the Keychain
    /// (a Keychain read can raise a macOS access prompt mid-capture).
    @Published private(set) var isConnected: Bool {
        didSet { defaults.set(isConnected, forKey: "drive.connected") }
    }
    @Published private(set) var isConnecting = false
    @Published var lastError: String?

    private let defaults = UserDefaults.standard
    private var loopback: OAuthLoopback?

    private init() {
        clientID = UserDefaults.standard.string(forKey: "drive.clientID") ?? ""
        // The developer-entered secret is only needed without an embedded client.
        clientSecret = DriveClientConfig.bundled == nil ? (Keychain.get("drive.clientSecret") ?? "") : ""
        if let stored = UserDefaults.standard.object(forKey: "drive.connected") as? Bool {
            isConnected = stored
        } else {
            // One-time migration from builds that kept this only in the Keychain.
            isConnected = Keychain.get("drive.refreshToken") != nil
            UserDefaults.standard.set(isConnected, forKey: "drive.connected")
        }
    }

    /// True when the app ships with its own OAuth client — users then only
    /// ever see the Connect button.
    var hasEmbeddedClient: Bool { DriveClientConfig.bundled != nil }

    private var effectiveClientID: String { DriveClientConfig.bundled?.id ?? clientID }
    private var effectiveClientSecret: String { DriveClientConfig.bundled?.secret ?? clientSecret }

    var isConfigured: Bool {
        !effectiveClientID.isEmpty && !effectiveClientSecret.isEmpty
    }

    // MARK: Connect / disconnect

    func connect() {
        // A previous attempt whose browser tab was closed: abandon it and retry.
        if isConnecting {
            loopback?.cancel()
            loopback = nil
        }
        lastError = nil
        isConnecting = true
        Task { @MainActor in
            defer { self.isConnecting = false }
            do {
                try await self.runOAuthFlow()
                self.isConnected = true
                Preferences.shared.enableDriveSyncDefaultsOnce()
            } catch {
                self.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func disconnect() {
        Keychain.delete("drive.refreshToken")
        Keychain.delete("drive.accessToken")
        defaults.removeObject(forKey: "drive.accessExpiry")
        defaults.removeObject(forKey: "drive.folderID")
        isConnected = false
    }

    private func runOAuthFlow() async throws {
        guard isConfigured else {
            throw DriveError("No Google OAuth client configured — see the hint below the fields.")
        }
        loopback?.cancel()
        let server = OAuthLoopback()
        loopback = server
        let port = try await server.start()

        let verifier = Self.randomVerifier()
        let challenge = Self.codeChallenge(for: verifier)
        let redirect = "http://127.0.0.1:\(port)"

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: effectiveClientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/drive.file"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        NSWorkspace.shared.open(components.url!)

        // Don't wait forever if the user closes the browser tab.
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak server] in server?.cancel() }
        let code = try await server.waitForCode()
        loopback = nil

        let token = try await Self.tokenRequest(parameters: [
            "client_id": effectiveClientID,
            "client_secret": effectiveClientSecret,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirect,
            "grant_type": "authorization_code",
        ])
        guard let refresh = token.refreshToken else {
            throw DriveError("Google did not return a refresh token — remove Snipost from your Google account's third-party access list and connect again.")
        }
        Keychain.set(refresh, for: "drive.refreshToken")
        storeAccessToken(token)
    }

    // MARK: Upload

    /// Uploads a PNG into the "Snipost" folder, makes it link-shareable, and
    /// returns the share URL.
    func uploadAndLink(_ image: CGImage, filename: String) async throws -> String {
        let token = try await validAccessToken()
        guard let png = await Task.detached(priority: .userInitiated, operation: { ImageWriter.pngData(image) }).value else {
            throw DriveError("Could not encode PNG")
        }
        var folder = try await ensureFolder(token: token)
        do {
            return try await upload(png: png, filename: filename, folder: folder, token: token)
        } catch let error as HTTPError where error.status == 404 || error.status == 400 {
            // The cached "Snipost" folder was deleted — find/create it again once.
            defaults.removeObject(forKey: "drive.folderID")
            folder = try await ensureFolder(token: token)
            return try await upload(png: png, filename: filename, folder: folder, token: token)
        }
    }

    private func upload(png: Data, filename: String, folder: String, token: String) async throws -> String {

        let boundary = "snipost-\(UUID().uuidString)"
        let metadata = try JSONSerialization.data(withJSONObject: ["name": filename, "parents": [folder]])
        var body = Data()
        body.appendString("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n")
        body.append(metadata)
        body.appendString("\r\n--\(boundary)\r\nContent-Type: image/png\r\n\r\n")
        body.append(png)
        body.appendString("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        try Net.check(response, data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fileID = json["id"] as? String
        else { throw DriveError("Unexpected upload response") }

        // Anyone with the link can view.
        var permission = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(fileID)/permissions")!)
        permission.httpMethod = "POST"
        permission.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        permission.setValue("application/json", forHTTPHeaderField: "Content-Type")
        permission.httpBody = try JSONSerialization.data(withJSONObject: ["role": "reader", "type": "anyone"])
        let (permData, permResponse) = try await URLSession.shared.data(for: permission)
        try Net.check(permResponse, permData)

        return "https://drive.google.com/file/d/\(fileID)/view?usp=sharing"
    }

    private func ensureFolder(token: String) async throws -> String {
        if let cached = defaults.string(forKey: "drive.folderID") { return cached }

        var query = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        query.queryItems = [
            URLQueryItem(name: "q", value: "name = 'Snipost' and mimeType = 'application/vnd.google-apps.folder' and trashed = false"),
            URLQueryItem(name: "fields", value: "files(id)"),
        ]
        var request = URLRequest(url: query.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Net.check(response, data)
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let files = json["files"] as? [[String: Any]],
           let id = files.first?["id"] as? String {
            defaults.set(id, forKey: "drive.folderID")
            return id
        }

        var create = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files?fields=id")!)
        create.httpMethod = "POST"
        create.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        create.setValue("application/json", forHTTPHeaderField: "Content-Type")
        create.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": "Snipost",
            "mimeType": "application/vnd.google-apps.folder",
        ])
        let (createData, createResponse) = try await URLSession.shared.data(for: create)
        try Net.check(createResponse, createData)
        guard let json = try JSONSerialization.jsonObject(with: createData) as? [String: Any],
              let id = json["id"] as? String
        else { throw DriveError("Could not create the Snipost folder") }
        defaults.set(id, forKey: "drive.folderID")
        return id
    }

    // MARK: Tokens

    private func validAccessToken() async throws -> String {
        if let token = Keychain.get("drive.accessToken"),
           defaults.double(forKey: "drive.accessExpiry") > Date().timeIntervalSince1970 + 60 {
            return token
        }
        guard let refresh = Keychain.get("drive.refreshToken") else {
            throw DriveError("Google Drive is not connected — connect it in Settings → Accounts.")
        }
        let token = try await Self.tokenRequest(parameters: [
            "client_id": effectiveClientID,
            "client_secret": effectiveClientSecret,
            "refresh_token": refresh,
            "grant_type": "refresh_token",
        ])
        storeAccessToken(token)
        return token.accessToken
    }

    private func storeAccessToken(_ token: TokenResponse) {
        Keychain.set(token.accessToken, for: "drive.accessToken")
        defaults.set(Date().timeIntervalSince1970 + Double(token.expiresIn), forKey: "drive.accessExpiry")
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: Int
        let refreshToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
        }
    }

    private static func tokenRequest(parameters: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Net.check(response, data)
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    // MARK: PKCE

    private static func randomVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 48)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    private static func codeChallenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
    }
}

struct DriveError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Tiny one-shot HTTP listener on 127.0.0.1 that catches Google's OAuth
/// redirect and hands back the authorization code.
final class OAuthLoopback {
    private var listener: NWListener?
    private var codeContinuation: CheckedContinuation<String, Error>?

    func start() async throws -> UInt16 {
        // Loopback only: nothing else on the network can reach the redirect.
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if !resumed {
                        resumed = true
                        continuation.resume(returning: listener.port?.rawValue ?? 0)
                    }
                case .failed(let error):
                    if !resumed {
                        resumed = true
                        continuation.resume(throwing: error)
                    }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: .main)
        }
    }

    func waitForCode() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            codeContinuation = continuation
        }
    }

    func cancel() {
        listener?.cancel()
        listener = nil
        codeContinuation?.resume(throwing: DriveError("Sign-in cancelled"))
        codeContinuation = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let firstLine = text.components(separatedBy: "\r\n").first ?? ""
            let parts = firstLine.components(separatedBy: " ")
            let path = parts.count > 1 ? parts[1] : ""
            let items = URLComponents(string: "http://localhost\(path)")?.queryItems ?? []
            let code = items.first(where: { $0.name == "code" })?.value
            let oauthError = items.first(where: { $0.name == "error" })?.value

            let html = """
            <html><body style="font-family:-apple-system;text-align:center;margin-top:80px">
            <h2>\(code != nil ? "Snipost is connected to Google Drive 🎉" : "Sign-in was not completed")</h2>
            <p>You can close this tab and return to Snipost.</p></body></html>
            """
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })

            if let code {
                self.codeContinuation?.resume(returning: code)
                self.codeContinuation = nil
                self.listener?.cancel()
                self.listener = nil
            } else if let oauthError {
                self.codeContinuation?.resume(throwing: DriveError("Google sign-in failed: \(oauthError)"))
                self.codeContinuation = nil
                self.listener?.cancel()
                self.listener = nil
            }
            // Requests without a code (e.g. /favicon.ico) keep the listener alive.
        }
    }
}
