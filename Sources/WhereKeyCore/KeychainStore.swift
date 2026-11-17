import Foundation
import LocalAuthentication
import Security

public protocol SecretStoring: AnyObject {
    func save(_ value: String, account: String) throws
    func read(account: String) throws -> String
    func read(account: String, interactive: Bool) throws -> String
    func delete(account: String) throws
}

public extension SecretStoring {
    func read(account: String, interactive: Bool) throws -> String { try read(account: account) }
}

public final class KeychainStore: SecretStoring {
    public static let serviceName = "com.wherekey.secrets"
    // The legacy login Keychain UI flag is process-wide; serialize every access
    // and restore it after each operation. LAContext alone does not cover all
    // legacy items. No Keychain ACL or system security setting is changed.
    private static let accessLock = NSRecursiveLock()
    private let readOperation: ([String: Any]) -> (Int32, Data?)

    public init(readOperation: (([String: Any]) -> (Int32, Data?))? = nil) {
        self.readOperation = readOperation ?? { query in
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result as? Data)
        }
    }

    public func save(_ value: String, account: String) throws {
        try withInteraction(false) { try saveValue(value, account: account) }
    }

    private func saveValue(_ value: String, account: String) throws {
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
        try read(account: account, interactive: false)
    }

    public func read(account: String, interactive: Bool) throws -> String {
        try withInteraction(interactive) {
        let context = LAContext()
        context.interactionNotAllowed = !interactive
        context.localizedReason = "允许 WhereKey 使用你选择的服务"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        let (status, data) = readOperation(query)
        guard status == errSecSuccess else {
            if status == errSecItemNotFound { throw WhereKeyError.notFound("秘密值不存在") }
            if status == errSecAuthFailed || status == errSecInteractionNotAllowed || status == errSecUserCanceled {
                throw WhereKeyError.authorizationRequired(account)
            }
            throw WhereKeyError.keychain(status)
        }
        guard let data, let value = String(data: data, encoding: .utf8) else {
            throw WhereKeyError.storage("Keychain 数据格式无效")
        }
        return value
        }
    }

    public func delete(account: String) throws {
        try withInteraction(false) { try deleteValue(account: account) }
    }

    private func deleteValue(account: String) throws {
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

    private func withInteraction<T>(_ interactive: Bool, _ action: () throws -> T) throws -> T {
        Self.accessLock.lock()
        defer { Self.accessLock.unlock() }
        var previous = DarwinBoolean(false)
        let getStatus = SecKeychainGetUserInteractionAllowed(&previous)
        guard getStatus == errSecSuccess else { throw WhereKeyError.keychain(getStatus) }
        let setStatus = SecKeychainSetUserInteractionAllowed(interactive)
        guard setStatus == errSecSuccess else { throw WhereKeyError.keychain(setStatus) }
        defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        return try action()
    }

    public static func credentialAccount(_ id: UUID) -> String { "credential.\(id.uuidString)" }
    public static func curlAccount(_ id: UUID) -> String { "curl.\(id.uuidString)" }
    public static func validationAccount(_ id: UUID) -> String { "validation.\(id.uuidString)" }
}
