import Foundation
import Security

/// The app's own Keychain item, holding a setup-token from `claude setup-token`.
///
/// Deliberately *not* Claude Code's `Claude Code-credentials` item: that one holds an
/// access token on a ~6 hour lease, so an always-on app reading it goes blind whenever
/// the CLI has not refreshed recently. It also belongs to another application, and a
/// differently-signed binary reading it triggers a Keychain access prompt.
enum TokenStore {
    static let service = "com.victorrodrigues.ClawBar"
    static let account = "setup-token"

    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty
        else { return nil }
        return token
    }

    @discardableResult
    static func write(_ token: String) -> Bool {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(identity as CFDictionary)   // upsert

        var item = identity
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        item[kSecAttrLabel as String] = "ClawBar — Claude usage token"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(identity as CFDictionary)
    }

    /// Cheap sanity check so onboarding can reject an obvious paste error before
    /// spending a network round trip on it.
    static func looksPlausible(_ token: String) -> Bool {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("sk-ant-") && t.count >= 40
    }
}
