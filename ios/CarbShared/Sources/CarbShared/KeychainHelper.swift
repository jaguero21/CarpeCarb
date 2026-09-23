import Foundation
import Security

/// Shared Keychain storage for values that need to be accessible across the
/// main app and its extensions (Widget, Siri App Intents).
///
/// Requires Keychain Sharing capability enabled in Xcode for all targets that
/// need access, with access group "group.com.carpecarb.shared" registered.
/// Until that capability is enabled, read/write fall back silently.
public struct KeychainHelper {
    // Keychain access group shared across app + extensions.
    // Enable via Xcode → Targets → Signing & Capabilities → + Keychain Sharing.
    private static let accessGroup = "group.com.carpecarb.shared"
    private static let service = "com.carpecarb"

    public static func save(_ value: String, forKey key: String) {
        guard let data = value.data(using: .utf8) else { return }

        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecAttrAccessGroup: accessGroup,
        ]

        // Try update first; if not found, add.
        let updateAttributes: [CFString: Any] = [kSecValueData: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            query[kSecValueData] = data
            query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    public static func load(forKey key: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecAttrAccessGroup: accessGroup,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    public static func delete(forKey key: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecAttrAccessGroup: accessGroup,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
