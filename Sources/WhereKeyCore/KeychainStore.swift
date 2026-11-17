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

// These internal operation seams let security tests exercise every failure path
// without touching the user's login keychain or changing a real UI policy.
struct KeychainOperations {
    var read: ([String: Any]) -> (OSStatus, Data?)
    var update: ([String: Any], [String: Any]) -> OSStatus
    var add: ([String: Any]) -> OSStatus
    var delete: ([String: Any]) -> OSStatus

    static func system(readOverride: (([String: Any]) -> (OSStatus, Data?))? = nil) -> Self {
        Self(read: readOverride ?? { query in
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result as? Data)
        }, update: { SecItemUpdate($0 as CFDictionary, $1 as CFDictionary) },
        add: { SecItemAdd($0 as CFDictionary, nil) },
        delete: { SecItemDelete($0 as CFDictionary) })
    }
}

struct KeychainInteractionOperations {
    var getAllowed: () -> (OSStatus, Bool)
    var setAllowed: (Bool) -> OSStatus

    static var system: Self {
        Self(getAllowed: {
            var allowed = DarwinBoolean(false)
            let status = SecKeychainGetUserInteractionAllowed(&allowed)
            return (status, allowed.boolValue)
        }, setAllowed: { SecKeychainSetUserInteractionAllowed($0) })
    }
}

public final class KeychainStore: SecretStoring {
    public static let serviceName = "com.wherekey.secrets"
    // The legacy login Keychain UI flag is process-wide. Serialize every access
    // across all store instances; LAContext alone only covers modern items.
    // Keep the legacy storage domain and existing ACLs intact: switching to the
    // Data Protection keychain or replacing ACLs is a separate migration.
    private static let accessLock = NSRecursiveLock()
    private let operations: KeychainOperations
    private let interaction: KeychainInteractionOperations

    public convenience init(readOperation: (([String: Any]) -> (Int32, Data?))? = nil) {
        self.init(operations: .system(readOverride: readOperation), interaction: .system)
    }

    init(operations: KeychainOperations, interaction: KeychainInteractionOperations) {
        self.operations = operations
        self.interaction = interaction
    }

    public func save(_ value: String, account: String) throws {
        try validateAccount(account)
        try withAuthentication(account: account, interactive: false) { query in
            guard let data = value.data(using: .utf8) else {
                throw WhereKeyError.invalidInput("秘密值不是有效 UTF-8")
            }
            let updateStatus = operations.update(query, [kSecValueData as String: data])
            if updateStatus == errSecSuccess { return }
            guard updateStatus == errSecItemNotFound else { throw operationError(updateStatus, account: account) }
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrLabel as String] = "WhereKey \(account)"
            // False is the documented default. Make the local-only intent
            // explicit for new items, without changing legacy lookup semantics.
            addQuery[kSecAttrSynchronizable as String] = false
            let addStatus = operations.add(addQuery)
            guard addStatus == errSecSuccess else { throw operationError(addStatus, account: account) }
        }
    }

    public func read(account: String) throws -> String { try read(account: account, interactive: false) }

    public func read(account: String, interactive: Bool) throws -> String {
        try validateAccount(account)
        return try withAuthentication(account: account, interactive: interactive) { query in
            var readQuery = query
            readQuery[kSecReturnData as String] = true
            readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
            let (status, data) = operations.read(readQuery)
            guard status == errSecSuccess else { throw operationError(status, account: account) }
            guard let data, let value = String(data: data, encoding: .utf8) else {
                throw WhereKeyError.storage("Keychain 数据格式无效")
            }
            return value
        }
    }

    public func delete(account: String) throws {
        try validateAccount(account)
        try withAuthentication(account: account, interactive: false) { query in
            let status = operations.delete(query)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw operationError(status, account: account) }
        }
    }

    private func validateAccount(_ account: String) throws {
        guard !account.isEmpty, account.utf8.count <= 1_024,
              !account.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw WhereKeyError.invalidInput("Keychain 账户标识无效")
        }
    }

    private func operationError(_ status: OSStatus, account: String) -> WhereKeyError {
        switch status {
        case errSecItemNotFound: return .notFound("秘密值不存在")
        case errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled:
            return .authorizationRequired(account)
        default: return .keychain(status)
        }
    }

    private func withAuthentication<T>(account: String, interactive: Bool,
                                       _ action: ([String: Any]) throws -> T) throws -> T {
        try withInteraction(interactive) {
            let context = LAContext()
            context.interactionNotAllowed = !interactive
            context.localizedReason = "允许 WhereKey 使用你选择的服务"
            defer { context.invalidate() }
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.serviceName,
                kSecAttrAccount as String: account,
                kSecUseAuthenticationContext as String: context,
            ]
            return try action(query)
        }
    }

    private func withInteraction<T>(_ interactive: Bool, _ action: () throws -> T) throws -> T {
        Self.accessLock.lock()
        defer { Self.accessLock.unlock() }
        let (getStatus, previous) = interaction.getAllowed()
        guard getStatus == errSecSuccess else { throw WhereKeyError.keychain(getStatus) }
        let setStatus = interaction.setAllowed(interactive)
        guard setStatus == errSecSuccess else {
            // A failed setter must never be followed by a secret operation.
            _ = interaction.setAllowed(false)
            throw WhereKeyError.keychain(setStatus)
        }
        let result = Result { try action() }
        let restoreStatus = interaction.setAllowed(previous)
        guard restoreStatus == errSecSuccess else {
            // Do not return a secret after losing the expected UI policy.
            // A best-effort quiet fallback is safer than leaving UI enabled.
            _ = interaction.setAllowed(false)
            throw WhereKeyError.keychain(restoreStatus)
        }
        return try result.get()
    }

    public static func credentialAccount(_ id: UUID) -> String { "credential.\(id.uuidString)" }
    public static func curlAccount(_ id: UUID) -> String { "curl.\(id.uuidString)" }
    public static func validationAccount(_ id: UUID) -> String { "validation.\(id.uuidString)" }
}
