import Foundation
import Security

public protocol SecretStoring: AnyObject {
    func save(_ value: String, account: String) throws
    func read(account: String) throws -> String
    func delete(account: String) throws
}

public final class KeychainStore: SecretStoring {
    public static let serviceName = "com.wherekey.secrets"

    public init() {}

    public func save(_ value: String, account: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw WhereKeyError.invalidInput("秘密值不是有效 UTF-8")
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw WhereKeyError.keychain(updateStatus)
        }
        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrLabel as String] = "WhereKey \(account)"
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw WhereKeyError.keychain(addStatus) }
    }

    public func read(account: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecAuthFailed {
            // macOS can transiently leave an unlocked login keychain in an
            // authentication-failed state after a process has run for a long time.
            // A few short retries avoid surfacing one-off failures; a persistent
            // failure is handled by the app's one-click restart action.
            for _ in 0..<2 where status == errSecAuthFailed {
                Thread.sleep(forTimeInterval: 0.12)
                result = nil
                status = SecItemCopyMatching(query as CFDictionary, &result)
            }
        }
        guard status == errSecSuccess else {
            if status == errSecItemNotFound { throw WhereKeyError.notFound("秘密值不存在") }
            throw WhereKeyError.keychain(status)
        }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw WhereKeyError.storage("Keychain 数据格式无效")
        }
        return value
    }

    public func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw WhereKeyError.keychain(status)
        }
    }

    public static func credentialAccount(_ id: UUID) -> String { "credential.\(id.uuidString)" }
    public static func curlAccount(_ id: UUID) -> String { "curl.\(id.uuidString)" }
    public static func validationAccount(_ id: UUID) -> String { "validation.\(id.uuidString)" }
}
