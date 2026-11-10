import Foundation
import Security

/// Minimal generic-password Keychain wrapper for tokens and app passwords.
enum Keychain {
    private static let service = "app.snipost.mac"

    static func set(_ value: String, for key: String) {
        if value.isEmpty {
            delete(key)
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        adoptIfNeeded(value, for: key)
        return value
    }

    /// Items written by an earlier, differently-signed build make macOS ask
    /// "allow Snipost to access…" on every read. Re-saving the item once from
    /// this build makes it ours, so the prompt never comes back.
    private static func adoptIfNeeded(_ value: String, for key: String) {
        let marker = "keychain.adopted.\(key)"
        guard !UserDefaults.standard.bool(forKey: marker) else { return }
        set(value, for: key)
        UserDefaults.standard.set(true, forKey: marker)
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
