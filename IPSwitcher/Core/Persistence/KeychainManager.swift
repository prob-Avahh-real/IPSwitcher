import Foundation
import Security

enum KeychainManager {
    static let service = "com.ipswitcher.tunnel"
    static let accountPassword = "tunnel_password"
    static let accountConfig = "app_config"

    // MARK: - Password Storage

    /// Store a password and return a persistent reference for NEVPNProtocol
    @discardableResult
    static func store(password: String, account: String = accountPassword) throws -> Data {
        guard let data = password.data(using: .utf8) else {
            throw KeychainError.invalidData
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        // Delete existing first
        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.storeFailed(status)
        }

        // Return persistent reference
        var ref: CFTypeRef?
        let copyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnPersistentRef as String: true,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let copyStatus = SecItemCopyMatching(copyQuery as CFDictionary, &ref)
        guard copyStatus == errSecSuccess, let refData = ref as? Data else {
            throw KeychainError.copyFailed(copyStatus)
        }
        return refData
    }

    /// Retrieve a password from Keychain
    static func retrieve(account: String = accountPassword) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8)
        else {
            throw KeychainError.retrieveFailed(status)
        }
        return password
    }

    /// Delete a password from Keychain
    static func delete(account: String = accountPassword) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    // MARK: - Codable Storage

    /// Store a Codable value in Keychain
    static func store<T: Encodable>(_ value: T, account: String) throws {
        let data = try JSONEncoder().encode(value)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.storeFailed(status)
        }
    }

    /// Retrieve a Codable value from Keychain
    static func retrieve<T: Decodable>(_ type: T.Type, account: String) throws -> T {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data
        else {
            throw KeychainError.retrieveFailed(status)
        }

        return try JSONDecoder().decode(type, from: data)
    }

    /// Check if an item exists in Keychain
    static func exists(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: false,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Remove all Keychain items for this app
    static func clearAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }
}

// MARK: - Errors

enum KeychainError: LocalizedError {
    case invalidData
    case storeFailed(OSStatus)
    case retrieveFailed(OSStatus)
    case copyFailed(OSStatus)
    case deleteFailed(OSStatus)
    case itemNotFound

    var errorDescription: String? {
        switch self {
        case .invalidData:
            return "数据格式无效"
        case .storeFailed(let status):
            return "存储失败 (OSStatus: \(status))"
        case .retrieveFailed(let status):
            return "读取失败 (OSStatus: \(status))"
        case .copyFailed(let status):
            return "复制失败 (OSStatus: \(status))"
        case .deleteFailed(let status):
            return "删除失败 (OSStatus: \(status))"
        case .itemNotFound:
            return "未找到项目"
        }
    }
}
