import Foundation

public struct CredentialDraft: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var alias: String
    public var environmentVariable: String
    public var secret: String
    public var existingSuffix: String
    public var isDefault: Bool

    public init(
        id: UUID = UUID(),
        alias: String = "default",
        environmentVariable: String = "",
        secret: String = "",
        existingSuffix: String = "",
        isDefault: Bool = true
    ) {
        self.id = id
        self.alias = alias
        self.environmentVariable = environmentVariable
        self.secret = secret
        self.existingSuffix = existingSuffix
        self.isDefault = isDefault
    }
}

public struct ServiceDraft: Identifiable, Equatable, Sendable {
    public var id: UUID?
    public var kind: ServiceKind
    public var name: String
    public var environmentVariable: String
    public var baseURL: String
    public var baseURLVariable: String
    public var credentials: [CredentialDraft]
    public var curlTemplate: String
    public var validationCurl: String
    public var validationRule: ValidationRule

    public init(
        id: UUID? = nil,
        kind: ServiceKind = .apiKey,
        name: String = "",
        environmentVariable: String = "API_KEY",
        baseURL: String = "",
        baseURLVariable: String = "",
        credentials: [CredentialDraft] = [CredentialDraft(environmentVariable: "API_KEY")],
        curlTemplate: String = "",
        validationCurl: String = "",
        validationRule: ValidationRule = ValidationRule()
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.environmentVariable = environmentVariable
        self.baseURL = baseURL
        self.baseURLVariable = baseURLVariable
        self.credentials = credentials
        self.curlTemplate = curlTemplate
        self.validationCurl = validationCurl
        self.validationRule = validationRule
    }
}

public struct PreparedRun: Codable, Sendable {
    public var environment: [String: String]
    public var secretsForRedaction: [String]
    public var serviceName: String
    public var credentialAlias: String
}

public struct ServiceDescription: Codable, Sendable {
    public var service: CatalogService
    public var usageProjects: [String]
}

public final class WhereKeyRepository: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let metadataStore: MetadataStore
    private let keychain: any SecretStoring
    private let validator: CurlValidator
    private var state: MetadataState

    public init(metadataStore: MetadataStore = MetadataStore(), keychain: any SecretStoring = KeychainStore(), validator: CurlValidator = CurlValidator()) throws {
        self.metadataStore = metadataStore
        self.keychain = keychain
        self.validator = validator
        self.state = try metadataStore.load()
    }

    public func snapshot() -> MetadataState {
        lock.withLock { state }
    }

    public func draft(for serviceID: UUID?) throws -> ServiceDraft {
        try lock.withLock {
            guard let serviceID else { return ServiceDraft() }
            guard let service = state.services.first(where: { $0.id == serviceID }) else {
                throw WhereKeyError.notFound("服务不存在")
            }
            let credentials = state.credentials
                .filter { $0.serviceID == service.id }
                .map {
                    CredentialDraft(
                        id: $0.id,
                        alias: $0.alias,
                        environmentVariable: $0.environmentVariable,
                        secret: "",
                        existingSuffix: $0.maskedSuffix,
                        isDefault: service.defaultCredentialID == $0.id
                    )
                }
            let curl = service.hasCurlTemplate ? (try keychain.read(account: KeychainStore.curlAccount(service.id))) : ""
            let validation = service.hasValidationRequest ? (try keychain.read(account: KeychainStore.validationAccount(service.id))) : ""
            return ServiceDraft(
                id: service.id,
                kind: service.kind,
                name: service.name,
                environmentVariable: service.environmentVariable,
                baseURL: service.baseURL,
                baseURLVariable: service.baseURLVariable,
                credentials: credentials,
                curlTemplate: curl,
                validationCurl: validation,
                validationRule: service.validationRule
            )
        }
    }

    @discardableResult
    public func save(_ draft: ServiceDraft) throws -> UUID {
        try lock.withLock {
            let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw WhereKeyError.invalidInput("请输入服务名称") }
            if state.services.contains(where: { $0.id != draft.id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                throw WhereKeyError.duplicate("服务名称已存在")
            }
            let serviceID = draft.id ?? UUID()
            var credentialDrafts = draft.credentials
            if draft.kind == .apiKey, credentialDrafts.isEmpty {
                throw WhereKeyError.invalidInput("API Key 服务至少需要一个 Key")
            }
            if !credentialDrafts.isEmpty {
                if credentialDrafts.filter(\.isDefault).count != 1 {
                    for index in credentialDrafts.indices { credentialDrafts[index].isDefault = index == 0 }
                }
            }
            var aliases = Set<String>()
            for item in credentialDrafts {
                let alias = item.alias.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !alias.isEmpty else { throw WhereKeyError.invalidInput("Key 别名不能为空") }
                guard aliases.insert(alias.lowercased()).inserted else { throw WhereKeyError.duplicate("同一服务中的 Key 别名不能重复") }
                let envName = item.environmentVariable.trimmingCharacters(in: .whitespacesAndNewlines)
                guard Self.isValidEnvironmentName(envName) else { throw WhereKeyError.invalidInput("环境变量名 \(envName) 无效") }
                if draft.id == nil || !state.credentials.contains(where: { $0.id == item.id }) {
                    guard !item.secret.isEmpty else { throw WhereKeyError.invalidInput("请输入 \(alias) 的 Key 值") }
                }
            }
            if draft.kind == .curl {
                guard !draft.curlTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw WhereKeyError.invalidInput("请粘贴 curl")
                }
                _ = try SafeCurl.parse(resolvePlaceholdersForValidation(draft.curlTemplate, drafts: credentialDrafts))
            }

            let previousCredentialIDs = Set(state.credentials.filter { $0.serviceID == serviceID }.map(\.id))
            let newCredentialIDs = Set(credentialDrafts.map(\.id))
            let removedCredentialIDs = previousCredentialIDs.subtracting(newCredentialIDs)
            let now = Date()
            var records: [CredentialRecord] = []
            for item in credentialDrafts {
                let existing = state.credentials.first(where: { $0.id == item.id })
                var suffix = existing?.maskedSuffix ?? item.existingSuffix
                if !item.secret.isEmpty {
                    try keychain.save(item.secret, account: KeychainStore.credentialAccount(item.id))
                    suffix = String(item.secret.suffix(4))
                }
                records.append(CredentialRecord(
                    id: item.id,
                    serviceID: serviceID,
                    alias: item.alias.trimmingCharacters(in: .whitespacesAndNewlines),
                    environmentVariable: item.environmentVariable.trimmingCharacters(in: .whitespacesAndNewlines),
                    maskedSuffix: suffix,
                    status: .unchecked,
                    lastCheckedAt: nil,
                    createdAt: existing?.createdAt ?? now,
                    updatedAt: now
                ))
            }

            var validationCurl = draft.validationCurl.trimmingCharacters(in: .whitespacesAndNewlines)
            if !validationCurl.isEmpty, let defaultDraft = credentialDrafts.first(where: \.isDefault) {
                let defaultSecret = !defaultDraft.secret.isEmpty
                    ? defaultDraft.secret
                    : (try? keychain.read(account: KeychainStore.credentialAccount(defaultDraft.id))) ?? ""
                if !defaultSecret.isEmpty {
                    validationCurl = validationCurl.replacingOccurrences(of: defaultSecret, with: "{{key}}")
                }
                _ = try SafeCurl.parse(validationCurl.replacingOccurrences(of: "{{key}}", with: "placeholder"))
                try keychain.save(validationCurl, account: KeychainStore.validationAccount(serviceID))
            } else {
                try? keychain.delete(account: KeychainStore.validationAccount(serviceID))
            }
            if draft.kind == .curl {
                try keychain.save(draft.curlTemplate, account: KeychainStore.curlAccount(serviceID))
            } else {
                try? keychain.delete(account: KeychainStore.curlAccount(serviceID))
            }

            let existingService = state.services.first(where: { $0.id == serviceID })
            let defaultID = credentialDrafts.first(where: \.isDefault)?.id
            let record = ServiceRecord(
                id: serviceID,
                name: name,
                kind: draft.kind,
                environmentVariable: draft.environmentVariable,
                baseURL: draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                baseURLVariable: draft.baseURLVariable.trimmingCharacters(in: .whitespacesAndNewlines),
                credentialIDs: credentialDrafts.map(\.id),
                defaultCredentialID: defaultID,
                hasCurlTemplate: draft.kind == .curl,
                hasValidationRequest: !validationCurl.isEmpty,
                validationRule: draft.validationRule,
                curlStatus: .unchecked,
                lastCheckedAt: nil,
                createdAt: existingService?.createdAt ?? now,
                updatedAt: now
            )
            state.services.removeAll { $0.id == serviceID }
            state.services.append(record)
            state.credentials.removeAll { $0.serviceID == serviceID }
            state.credentials.append(contentsOf: records)
            try metadataStore.save(state)
            for id in removedCredentialIDs { try? keychain.delete(account: KeychainStore.credentialAccount(id)) }
            return serviceID
        }
    }

    public func deleteService(_ id: UUID) throws {
        try lock.withLock {
            guard state.services.contains(where: { $0.id == id }) else { return }
            let credentials = state.credentials.filter { $0.serviceID == id }
            state.services.removeAll { $0.id == id }
            state.credentials.removeAll { $0.serviceID == id }
            try metadataStore.save(state)
            for credential in credentials { try? keychain.delete(account: KeychainStore.credentialAccount(credential.id)) }
            try? keychain.delete(account: KeychainStore.curlAccount(id))
            try? keychain.delete(account: KeychainStore.validationAccount(id))
        }
    }

    public func catalog() -> [CatalogService] {
        lock.withLock {
            state.services.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }.map { service in
                let credentials = state.credentials.filter { $0.serviceID == service.id }
                let redactedCurl: String?
                if service.hasCurlTemplate, let value = try? keychain.read(account: KeychainStore.curlAccount(service.id)) {
                    redactedCurl = redact(value, credentials: credentials)
                } else { redactedCurl = nil }
                return CatalogService(
                    name: service.name,
                    kind: service.kind,
                    status: aggregateStatus(service: service, credentials: credentials),
                    baseURL: service.baseURL,
                    baseURLVariable: service.baseURLVariable,
                    credentials: credentials.map {
                        CatalogCredential(alias: $0.alias, environmentVariable: $0.environmentVariable, isDefault: service.defaultCredentialID == $0.id, status: $0.status)
                    },
                    redactedCurl: redactedCurl
                )
            }
        }
    }

    public func describe(service name: String) throws -> ServiceDescription {
        try lock.withLock {
            guard let catalogService = catalog().first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }),
                  let service = state.services.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw WhereKeyError.notFound("找不到服务：\(name)")
            }
            let projects = projectPaths(for: service.id, credentialID: nil)
            return ServiceDescription(service: catalogService, usageProjects: projects)
        }
    }

    public func prepareRun(service name: String, keyAlias: String?, cwd: String) throws -> PreparedRun {
        try lock.withLock {
            let service = try findService(name)
            let credential = try selectCredential(for: service, alias: keyAlias)
            guard let credential else {
                throw WhereKeyError.invalidInput("该 curl 服务没有可注入的 Key，请使用 wherekey call")
            }
            let secret = try keychain.read(account: KeychainStore.credentialAccount(credential.id))
            var environment = [credential.environmentVariable: secret]
            if !service.baseURL.isEmpty, !service.baseURLVariable.isEmpty {
                environment[service.baseURLVariable] = service.baseURL
            }
            try recordUsage(path: cwd, service: service, credential: credential)
            return PreparedRun(environment: environment, secretsForRedaction: [secret], serviceName: service.name, credentialAlias: credential.alias)
        }
    }

    public func call(service name: String, keyAlias: String?, cwd: String) throws -> CheckResult {
        try lock.withLock {
            let service = try findService(name)
            guard service.kind == .curl, service.hasCurlTemplate else {
                throw WhereKeyError.invalidInput("只有 curl 服务可以直接调用")
            }
            let template = try keychain.read(account: KeychainStore.curlAccount(service.id))
            let secrets = try secrets(for: service, selectedAlias: keyAlias)
            let credential = try selectCredential(for: service, alias: keyAlias)
            let result = try validator.execute(template: template, secrets: secrets, rule: service.validationRule, returnBody: true)
            try recordUsage(path: cwd, service: service, credential: credential)
            updateStatus(serviceID: service.id, credentialID: credential?.id, result: result)
            return result
        }
    }

    public func check(service name: String, keyAlias: String?) throws -> CheckResult {
        try lock.withLock {
            let service = try findService(name)
            let credential = try selectCredential(for: service, alias: keyAlias)
            let template: String
            if service.kind == .curl {
                template = try keychain.read(account: KeychainStore.curlAccount(service.id))
            } else {
                if service.hasValidationRequest {
                    template = try keychain.read(account: KeychainStore.validationAccount(service.id))
                } else if let generated = automaticValidationTemplate(for: service) {
                    template = generated
                } else {
                    let result = CheckResult(
                        status: .invalid,
                        httpStatus: nil,
                        elapsedMilliseconds: 0,
                        message: "缺少可检查的 API 地址"
                    )
                    updateStatus(serviceID: service.id, credentialID: credential?.id, result: result)
                    return result
                }
            }
            let secrets = try secrets(for: service, selectedAlias: keyAlias)
            let result = try validator.execute(template: template, secrets: secrets, rule: service.validationRule, returnBody: false)
            updateStatus(serviceID: service.id, credentialID: credential?.id, result: result)
            return result
        }
    }

    public func checkAll() -> [(String, CheckResult)] {
        let names = lock.withLock { state.services.map(\.name) }
        return names.map { name in
            do { return (name, try check(service: name, keyAlias: nil)) }
            catch { return (name, CheckResult(status: .invalid, httpStatus: nil, elapsedMilliseconds: 0, message: error.localizedDescription)) }
        }
    }

    public func checkAllAPIKeys() -> [(String, String, CheckResult)] {
        let targets: [(String, String)] = lock.withLock {
            state.services
                .filter { $0.kind == .apiKey }
                .flatMap { service in
                    state.credentials
                        .filter { $0.serviceID == service.id }
                        .map { (service.name, $0.alias) }
                }
        }
        return targets.map { serviceName, alias in
            do { return (serviceName, alias, try check(service: serviceName, keyAlias: alias)) }
            catch {
                return (
                    serviceName,
                    alias,
                    CheckResult(status: .invalid, httpStatus: nil, elapsedMilliseconds: 0, message: error.localizedDescription)
                )
            }
        }
    }

    public func projectPaths(for serviceID: UUID, credentialID: UUID?) -> [String] {
        lock.withLock {
            let projectIDs = Set(state.usages.filter {
                $0.serviceID == serviceID && (credentialID == nil || $0.credentialID == credentialID)
            }.map(\.projectID))
            return state.projects.filter { projectIDs.contains($0.id) }.map(\.path).sorted()
        }
    }

    public func serviceStatus(_ service: ServiceRecord) -> HealthStatus {
        lock.withLock { aggregateStatus(service: service, credentials: state.credentials.filter { $0.serviceID == service.id }) }
    }

    private func findService(_ name: String) throws -> ServiceRecord {
        guard let service = state.services.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.id.uuidString == name }) else {
            throw WhereKeyError.notFound("找不到服务：\(name)")
        }
        return service
    }

    private func selectCredential(for service: ServiceRecord, alias: String?) throws -> CredentialRecord? {
        let available = state.credentials.filter { $0.serviceID == service.id }
        if let alias, !alias.isEmpty {
            guard let selected = available.first(where: { $0.alias.caseInsensitiveCompare(alias) == .orderedSame }) else {
                throw WhereKeyError.notFound("服务 \(service.name) 中没有 Key：\(alias)")
            }
            return selected
        }
        if let defaultID = service.defaultCredentialID { return available.first(where: { $0.id == defaultID }) }
        return available.first
    }

    private func secrets(for service: ServiceRecord, selectedAlias: String?) throws -> [String: String] {
        let credentials = state.credentials.filter { $0.serviceID == service.id }
        var values: [String: String] = [:]
        for credential in credentials {
            values[credential.alias] = try keychain.read(account: KeychainStore.credentialAccount(credential.id))
        }
        if let selected = try selectCredential(for: service, alias: selectedAlias), let value = values[selected.alias] {
            values["__default"] = value
        }
        return values
    }

    private func automaticValidationTemplate(for service: ServiceRecord) -> String? {
        guard service.kind == .apiKey,
              let components = URLComponents(string: service.baseURL),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased() else { return nil }

        let origin = "\(scheme)://\(components.host ?? host)" + (components.port.map { ":\($0)" } ?? "")
        let url: String
        let headers: [String]

        switch host {
        case "api.anthropic.com":
            url = "\(origin)/v1/models"
            headers = ["x-api-key: {{key}}", "anthropic-version: 2023-06-01"]
        case "api.deepseek.com":
            url = "\(origin)/models"
            headers = ["Authorization: Bearer {{key}}"]
        case "api.openai.com":
            url = "\(origin)/v1/models"
            headers = ["Authorization: Bearer {{key}}"]
        case "api.moonshot.cn":
            url = "\(origin)/v1/models"
            headers = ["Authorization: Bearer {{key}}"]
        case "open.bigmodel.cn":
            url = "\(origin)/api/paas/v4/models"
            headers = ["Authorization: Bearer {{key}}"]
        case "api.x.ai":
            url = "\(origin)/v1/models"
            headers = ["Authorization: Bearer {{key}}"]
        case "api.groq.com":
            url = "\(origin)/openai/v1/models"
            headers = ["Authorization: Bearer {{key}}"]
        case "api.mistral.ai", "api.siliconflow.cn":
            url = "\(origin)/v1/models"
            headers = ["Authorization: Bearer {{key}}"]
        case "dashscope.aliyuncs.com":
            url = "\(origin)/compatible-mode/v1/models"
            headers = ["Authorization: Bearer {{key}}"]
        case "ark.cn-beijing.volces.com":
            url = "\(origin)/api/v3/models"
            headers = ["Authorization: Bearer {{key}}"]
        case "api.cohere.com":
            url = "\(origin)/v1/models"
            headers = ["Authorization: Bearer {{key}}"]
        case "openrouter.ai":
            // The public model catalog returns 200 without a key. This endpoint
            // verifies the configured API key itself without running a model.
            url = "\(origin)/api/v1/auth/key"
            headers = ["Authorization: Bearer {{key}}"]
        case "generativelanguage.googleapis.com":
            url = "\(origin)/v1beta/models"
            headers = ["x-goog-api-key: {{key}}"]
        default:
            url = service.baseURL
            headers = ["Authorization: Bearer {{key}}"]
        }

        return (["curl '\(url)'"] + headers.map { "-H '\($0)'" }).joined(separator: " ")
    }

    private func recordUsage(path: String, service: ServiceRecord, credential: CredentialRecord?) throws {
        let canonical = Self.canonicalPath(path)
        let now = Date()
        let project: ProjectRecord
        if let index = state.projects.firstIndex(where: { $0.path == canonical }) {
            state.projects[index].lastUsedAt = now
            project = state.projects[index]
        } else {
            project = ProjectRecord(path: canonical, createdAt: now, lastUsedAt: now)
            state.projects.append(project)
        }
        if let index = state.usages.firstIndex(where: {
            $0.projectID == project.id && $0.serviceID == service.id && $0.credentialID == credential?.id
        }) {
            state.usages[index].lastUsedAt = now
        } else {
            state.usages.append(UsageRecord(
                projectID: project.id,
                serviceID: service.id,
                credentialID: credential?.id,
                serviceNameSnapshot: service.name,
                credentialAliasSnapshot: credential?.alias ?? "无 Key",
                firstUsedAt: now,
                lastUsedAt: now
            ))
        }
        try metadataStore.save(state)
    }

    private func updateStatus(serviceID: UUID, credentialID: UUID?, result: CheckResult) {
        let now = Date()
        if let index = state.services.firstIndex(where: { $0.id == serviceID }) {
            state.services[index].curlStatus = result.status
            state.services[index].lastCheckedAt = now
        }
        if let credentialID, let index = state.credentials.firstIndex(where: { $0.id == credentialID }) {
            state.credentials[index].status = result.status
            state.credentials[index].lastCheckedAt = now
        }
        try? metadataStore.save(state)
    }

    private func aggregateStatus(service: ServiceRecord, credentials: [CredentialRecord]) -> HealthStatus {
        if service.kind == .curl { return service.curlStatus }
        guard !credentials.isEmpty else { return .unchecked }
        if let defaultID = service.defaultCredentialID, let value = credentials.first(where: { $0.id == defaultID }) { return value.status }
        return credentials[0].status
    }

    private func redact(_ template: String, credentials: [CredentialRecord]) -> String {
        var value = SafeCurl.redacted(template)
        for credential in credentials {
            value = value.replacingOccurrences(of: "{{secret:\(credential.alias)}}", with: "${\(credential.environmentVariable)}")
        }
        return value
    }

    private func resolvePlaceholdersForValidation(_ template: String, drafts: [CredentialDraft]) -> String {
        var value = template
        for draft in drafts {
            value = value.replacingOccurrences(of: "{{secret:\(draft.alias)}}", with: "placeholder")
        }
        return value
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func isValidEnvironmentName(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
    }
}

private extension NSRecursiveLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
