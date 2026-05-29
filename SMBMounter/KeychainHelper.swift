import Foundation
import Security

class KeychainHelper {
    static let shared = KeychainHelper()
    private let service = "com.smbmounter.passwords"

    func savePassword(_ password: String, for shareID: UUID) {
        let account = shareID.uuidString
        let data = Data(password.utf8)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        // Note: no kSecAttrAccessible. That is a data-protection-keychain attribute;
        // on the legacy keychain it wraps the data in a separate protection-class key
        // with its own ACL, which makes a read prompt twice (once for the item, once
        // for the key). A plain generic-password item only authorizes once.
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if status == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData as String] = data
            SecItemAdd(newItem as CFDictionary, nil)
        }
    }

    func getPassword(for shareID: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: shareID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            return nil
        }
        return password
    }

    func deletePassword(for shareID: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: shareID.uuidString
        ]
        SecItemDelete(query as CFDictionary)
    }
}
