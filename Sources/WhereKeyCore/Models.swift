import Foundation

public enum ServiceCategory: String, Codable, CaseIterable, Sendable {
    case ai, search, data, custom, other

    public var displayName: String {
        switch self {
        case .ai: return "大模型"
        case .search: return "搜索"
        case .data: return "数据服务"
        case .custom: return "自建服务"
        case .other: return "其他"
        }
    }
}

public enum CheckMode: String, Codable, CaseIterable, Sendable {
    case disabled, manual, automatic

    public var displayName: String {
        switch self {
        case .disabled: return "不检查"
        case .manual: return "手动检查"
        case .automatic: return "自动检查"
        }
    }
}

public enum AuthenticationKind: String, Codable, CaseIterable, Sendable {
    case providerPreset, bearer, header, query, none

    public var displayName: String {
        switch self {
        case .providerPreset: return "已知厂商预设"
        case .bearer: return "Bearer Token"
        case .header: return "自定义 Header"
        case .query: return "Query 参数"
        case .none: return "无鉴权"
        }
    }
}

public struct Authentication: Codable, Equatable, Sendable {
    public var kind: AuthenticationKind
    public var fieldName: String

    public init(kind: AuthenticationKind = .providerPreset, fieldName: String = "") {
        self.kind = kind
        self.fieldName = fieldName
    }
}

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
    case unavailable
    case rateLimited
    case forbidden
    case failed
    case authorizationRequired

    public var displayName: String {
        switch self {
        case .valid: return "可用"
        case .invalid: return "鉴权失败"
        case .unchecked: return "未验证"
        case .tlsUnverified: return "TLS 未验证"
        case .unavailable: return "连接异常"
        case .rateLimited: return "请求限流"
        case .forbidden: return "权限不足"
        case .failed: return "检查未通过"
        case .authorizationRequired: return "待授权"
        }
    }

    public var isFailure: Bool {
        switch self {
        case .valid, .unchecked, .tlsUnverified: return false
        default: return true
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
    public var category: ServiceCategory
    public var summary: String
    public var tags: [String]
    public var documentationURL: String
    public var checkMode: CheckMode
    public var checkURL: String
    public var authentication: Authentication
    public var allowsLegacyCurlCheck: Bool
    public var requiresBaseURL: Bool
    public var checkPath: String
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
        category: ServiceCategory = .custom,
        summary: String = "",
        tags: [String] = [],
        documentationURL: String = "",
        checkMode: CheckMode = .manual,
        checkURL: String = "",
        authentication: Authentication = Authentication(),
        allowsLegacyCurlCheck: Bool = false,
        requiresBaseURL: Bool = false,
        checkPath: String = "",
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
        self.category = category
        self.summary = summary
        self.tags = tags
        self.documentationURL = documentationURL
        self.checkMode = checkMode
        self.checkURL = checkURL
        self.authentication = authentication
        self.allowsLegacyCurlCheck = allowsLegacyCurlCheck
        self.requiresBaseURL = requiresBaseURL
        self.checkPath = checkPath
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

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, category, summary, tags, documentationURL, checkMode, checkURL, authentication, allowsLegacyCurlCheck, requiresBaseURL, checkPath
        case environmentVariable, baseURL, baseURLVariable, credentialIDs, defaultCredentialID
        case hasCurlTemplate, hasValidationRequest, validationRule, curlStatus, lastCheckedAt, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(ServiceKind.self, forKey: .kind)
        category = try c.decodeIfPresent(ServiceCategory.self, forKey: .category) ?? .other
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        documentationURL = try c.decodeIfPresent(String.self, forKey: .documentationURL) ?? ""
        checkMode = try c.decodeIfPresent(CheckMode.self, forKey: .checkMode) ?? (kind == .apiKey ? .automatic : .manual)
        checkURL = try c.decodeIfPresent(String.self, forKey: .checkURL) ?? ""
        authentication = try c.decodeIfPresent(Authentication.self, forKey: .authentication) ?? Authentication()
        allowsLegacyCurlCheck = try c.decodeIfPresent(Bool.self, forKey: .allowsLegacyCurlCheck) ?? (kind == .curl)
        requiresBaseURL = try c.decodeIfPresent(Bool.self, forKey: .requiresBaseURL) ?? false
        checkPath = try c.decodeIfPresent(String.self, forKey: .checkPath) ?? ""
        environmentVariable = try c.decode(String.self, forKey: .environmentVariable)
        baseURL = try c.decode(String.self, forKey: .baseURL)
        baseURLVariable = try c.decode(String.self, forKey: .baseURLVariable)
        credentialIDs = try c.decode([UUID].self, forKey: .credentialIDs)
        defaultCredentialID = try c.decodeIfPresent(UUID.self, forKey: .defaultCredentialID)
        hasCurlTemplate = try c.decode(Bool.self, forKey: .hasCurlTemplate)
        hasValidationRequest = try c.decode(Bool.self, forKey: .hasValidationRequest)
        validationRule = try c.decode(ValidationRule.self, forKey: .validationRule)
        curlStatus = try c.decode(HealthStatus.self, forKey: .curlStatus)
        lastCheckedAt = try c.decodeIfPresent(Date.self, forKey: .lastCheckedAt)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }

    public func matches(search: String) -> Bool {
        search.isEmpty || ([name, summary, category.displayName] + tags)
            .contains { $0.localizedCaseInsensitiveContains(search) }
    }

    public var setupMessage: String? {
        let needsKey = kind == .apiKey && credentialIDs.isEmpty
        let needsAddress = requiresBaseURL && baseURL.isEmpty
        if needsKey && needsAddress { return "待补 Key 和地址" }
        if needsKey { return "待补 Key" }
        if needsAddress { return "待补地址" }
        return nil
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
        schemaVersion: Int = 2,
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
    public var category: ServiceCategory
    public var summary: String
    public var tags: [String]
    public var documentationURL: String
    public var checkMode: CheckMode
    public var setupMessage: String?
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
    case authorizationRequired(String)

    public var errorDescription: String? {
        switch self {
        case .invalidInput(let value), .notFound(let value), .duplicate(let value),
             .storage(let value), .unsafeCurl(let value), .unavailable(let value),
             .ipcConnection(let value): return value
        case .authorizationRequired:
            return "此服务需要钥匙串授权。请在 WhereKey 中点击对应服务的“授权”，不会自动重试或读取其他服务。"
        case .keychain(let status):
            if status == -25293 {
                return "系统钥匙串暂时拒绝访问。请重新打开 WhereKey 后再试。"
            }
            return "Keychain 操作失败（\(status)）"
        }
    }
}
