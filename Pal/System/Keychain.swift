import Foundation
import Security

/// API keys live in the login Keychain, never in Pal's settings file.
enum Keychain {
    private static let service = "app.pal.mac"

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        delete(account)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
    }

    static let anthropicAccount = "anthropic-api-key"

    /// Testing aid: `--args -debugAPIBase http://127.0.0.1:8787 -debugAPIKey test` points the API backend at a mock.
    static var debugAPIBase: String? { UserDefaults.standard.string(forKey: "debugAPIBase") }

    static var anthropicKey: String? {
        if debugAPIBase != nil, let k = UserDefaults.standard.string(forKey: "debugAPIKey") { return k }
        return get(anthropicAccount)
    }
}
