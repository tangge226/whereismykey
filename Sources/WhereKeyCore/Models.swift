import Foundation

public enum ServiceKind: String, Codable, CaseIterable, Sendable {
    case apiKey
    case curl

    public var displayName: String {
        switch self {
        case .apiKey: return "API Key"
        case .curl: return "curl 服务"
        }
    }
}

public enum HealthStatus: String, Codable, CaseIterable, Sendable {
    case valid
    case invalid
    case unchecked
    case tlsUnverified

    public var displayName: String {
        switch self {
        case .valid: return "可用"
        case .invalid: return "失效"
        case .unchecked: return "未检查"
        case .tlsUnverified: return "TLS 未验证"
        }
    }
}

public struct ValidationRule: Codable, Equatable, Sendable {
    public var acceptedStatusCodes: String
    public var bodyContains: String
    public var jsonPath: String
    public var jsonExpectedValue: String
    public var timeoutSeconds: Int

    public init(
        acceptedStatusCodes: String = "200-299",
        bodyContains: String = "",
        jsonPath: String = "",
        jsonExpectedValue: String = "",
        timeoutSeconds: Int = 10
    ) {
        self.acceptedStatusCodes = acceptedStatusCodes
        self.bodyContains = bodyContains
        self.jsonPath = jsonPath
        self.jsonExpectedValue = jsonExpectedValue
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct ServiceRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: ServiceKind
    public var environmentVariable: String
    public var baseURL: String
    public var baseURLVariable: String
    public var credentialIDs: [UUID]
    public var defaultCredentialID: UUID?
    public var hasCurlTemplate: Bool
    public var hasValidationRequest: Bool
    public var validationRule: ValidationRule
    public var curlStatus: HealthStatus
    public var lastCheckedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        kind: ServiceKind,
        environmentVariable: String = "",
        baseURL: String = "",
        baseURLVariable: String = "",
        credentialIDs: [UUID] = [],
        defaultCredentialID: UUID? = nil,
        hasCurlTemplate: Bool = false,
        hasValidationRequest: Bool = false,
        validationRule: ValidationRule = ValidationRule(),
        curlStatus: HealthStatus = .unchecked,
        lastCheckedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.environmentVariable = environmentVariable
        self.baseURL = baseURL
        self.baseURLVariable = baseURLVariable
        self.credentialIDs = credentialIDs
        self.defaultCredentialID = defaultCredentialID
        self.hasCurlTemplate = hasCurlTemplate
        self.hasValidationRequest = hasValidationRequest
        self.validationRule = validationRule
        self.curlStatus = curlStatus
        self.lastCheckedAt = lastCheckedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct CredentialRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var serviceID: UUID
    public var alias: String
    public var environmentVariable: String
    public var maskedSuffix: String
    public var status: HealthStatus
    public var lastCheckedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        serviceID: UUID,
        alias: String,
        environmentVariable: String,
        maskedSuffix: String,
        status: HealthStatus = .unchecked,
        lastCheckedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.serviceID = serviceID
        self.alias = alias
        self.environmentVariable = environmentVariable
        self.maskedSuffix = maskedSuffix
        self.status = status
        self.lastCheckedAt = lastCheckedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var maskedValue: String {
        maskedSuffix.isEmpty ? "••••••••" : "••••••\(maskedSuffix)"
    }
}

public struct ProjectRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var path: String
    public var createdAt: Date
    public var lastUsedAt: Date

    public init(id: UUID = UUID(), path: String, createdAt: Date = Date(), lastUsedAt: Date = Date()) {
        self.id = id
        self.path = path
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }
}

public struct UsageRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var projectID: UUID
    public var serviceID: UUID
    public var credentialID: UUID?
    public var serviceNameSnapshot: String
    public var credentialAliasSnapshot: String
    public var firstUsedAt: Date
    public var lastUsedAt: Date

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        serviceID: UUID,
        credentialID: UUID?,
        serviceNameSnapshot: String,
        credentialAliasSnapshot: String,
        firstUsedAt: Date = Date(),
        lastUsedAt: Date = Date()
    ) {
        self.id = id
        self.projectID = projectID
        self.serviceID = serviceID
        self.credentialID = credentialID
        self.serviceNameSnapshot = serviceNameSnapshot
        self.credentialAliasSnapshot = credentialAliasSnapshot
        self.firstUsedAt = firstUsedAt
        self.lastUsedAt = lastUsedAt
    }
}

public struct MetadataState: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var services: [ServiceRecord]
    public var credentials: [CredentialRecord]
    public var projects: [ProjectRecord]
    public var usages: [UsageRecord]

    public init(
        schemaVersion: Int = 1,
        services: [ServiceRecord] = [],
        credentials: [CredentialRecord] = [],
        projects: [ProjectRecord] = [],
        usages: [UsageRecord] = []
    ) {
        self.schemaVersion = schemaVersion
        self.services = services
        self.credentials = credentials
        self.projects = projects
        self.usages = usages
    }
}

public struct CheckResult: Codable, Equatable, Sendable {
    public var status: HealthStatus
    public var httpStatus: Int?
    public var elapsedMilliseconds: Int
    public var message: String
    public var responsePreview: String

    public init(status: HealthStatus, httpStatus: Int?, elapsedMilliseconds: Int, message: String, responsePreview: String = "") {
        self.status = status
        self.httpStatus = httpStatus
        self.elapsedMilliseconds = elapsedMilliseconds
        self.message = message
        self.responsePreview = responsePreview
    }
}

public struct CatalogCredential: Codable, Sendable {
    public var alias: String
    public var environmentVariable: String
    public var isDefault: Bool
    public var status: HealthStatus
}

public struct CatalogService: Codable, Sendable {
    public var name: String
    public var kind: ServiceKind
    public var status: HealthStatus
    public var baseURL: String
    public var baseURLVariable: String
    public var credentials: [CatalogCredential]
    public var redactedCurl: String?
}

public enum WhereKeyError: LocalizedError, Equatable {
    case invalidInput(String)
    case notFound(String)
    case duplicate(String)
    case keychain(Int32)
    case ipcConnection(String)
    case storage(String)
    case unsafeCurl(String)
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .invalidInput(let value), .notFound(let value), .duplicate(let value),
             .storage(let value), .unsafeCurl(let value), .unavailable(let value),
             .ipcConnection(let value): return value
        case .keychain(let status):
            if status == -25293 {
                return "系统钥匙串暂时拒绝访问。请重新打开 WhereKey 后再试。"
            }
            return "Keychain 操作失败（\(status)）"
        }
    }
}
