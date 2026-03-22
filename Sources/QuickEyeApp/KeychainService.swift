import Foundation
import Security

struct KeychainService {
    enum Error: LocalizedError {
        case unexpectedStatus(OSStatus)
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case let .unexpectedStatus(status):
                return "Keychain operation failed with status \(status)."
            case .encodingFailed:
                return "Quick Eye could not encode the API key for storage."
            }
        }
    }

    let service: String

    func string(forAccount account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setString(_ string: String, forAccount account: String) throws {
        guard let data = string.data(using: .utf8) else {
            throw Error.encodingFailed
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributesToUpdate: [String: Any] = [
            kSecValueData as String: data,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        guard updateStatus == errSecItemNotFound else {
            throw Error.unexpectedStatus(updateStatus)
        }

        var insertQuery = query
        insertQuery[kSecValueData as String] = data
        let insertStatus = SecItemAdd(insertQuery as CFDictionary, nil)
        guard insertStatus == errSecSuccess else {
            throw Error.unexpectedStatus(insertStatus)
        }
    }

    func deleteString(forAccount account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Error.unexpectedStatus(status)
        }
    }
}
