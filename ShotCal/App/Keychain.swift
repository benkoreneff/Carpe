import Foundation
import Security

/// Secrets live in the login Keychain as generic passwords under the app's
/// bundle ID. Nothing secret goes into UserDefaults or the repository.
enum Keychain {
    typealias Item = Secret

    struct Failure: LocalizedError {
        var status: OSStatus
        var errorDescription: String? {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            return "Keychain: \(message)"
        }
    }

    private static let service = "com.koreneff.ShotCal"

    static func get(_ item: Item) -> String? {
        var query = baseQuery(item)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Stores the value, or removes the item when the value is nil.
    static func set(_ value: String?, for item: Item) throws {
        let query = baseQuery(item)
        guard let value else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
            return
        }

        let data = Data(value.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData] = data
            attributes[kSecAttrLabel] = "ShotCal (\(item.rawValue))"
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    private static func baseQuery(_ item: Item) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: item.rawValue,
        ]
    }
}

/// The Keychain as a `SecretStore`, for code in Core that takes one.
struct KeychainStore: SecretStore {
    func get(_ secret: Secret) -> String? { Keychain.get(secret) }
    func set(_ value: String?, for secret: Secret) throws { try Keychain.set(value, for: secret) }
}
