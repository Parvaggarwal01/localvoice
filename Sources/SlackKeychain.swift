import Foundation
import Security

/// The Helm Slack bot token (xoxb-…) lives only in the login Keychain, never in files or defaults.
enum SlackKeychain {
    private static let service = Bundle.main.bundleIdentifier ?? "com.localvoice.app"
    private static let account = "SLACK_BOT_TOKEN"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty else { return nil }
        return token
    }

    static func save(_ token: String) throws {
        let data = Data(token.utf8)
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw SlackKeychainError(status: addStatus) }
        } else if status != errSecSuccess {
            throw SlackKeychainError(status: status)
        }
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

private struct SlackKeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Couldn’t save the Slack token in Keychain (\(status))."
    }
}
