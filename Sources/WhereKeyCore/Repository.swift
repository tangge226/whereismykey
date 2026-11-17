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
    public var category: ServiceCategory
    public var summary: String
    public var tags: [String]
    public var documentationURL: String
    public var checkMode: CheckMode
    public var checkURL: String
    public var authentication: Authentication
    public var allowsLegacyCurlCheck: Bool
    public var allowsIncomplete: Bool
    public var requiresBaseURL: Bool
    public var checkPath: String
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
        category: ServiceCategory = .custom,
        summary: String = "",
        tags: [String] = [],
        documentationURL: String = "",
        checkMode: CheckMode = .manual,
        checkURL: String = "",
        authentication: Authentication = Authentication(),
        allowsLegacyCurlCheck: Bool = false,
        allowsIncomplete: Bool = false,
        requiresBaseURL: Bool = false,
        checkPath: String = "",
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
        self.category = category
        self.summary = summary
        self.tags = tags
        self.documentationURL = documentationURL
        self.checkMode = checkMode
        self.checkURL = checkURL
        self.authentication = authentication
        self.allowsLegacyCurlCheck = allowsLegacyCurlCheck
        self.allowsIncomplete = allowsIncomplete
        self.requiresBaseURL = requiresBaseURL
        self.checkPath = checkPath
        self.environmentVariable = environmentVariable
        self.baseURL = baseURL
        self.baseURLVariable = baseURLVariable
        self.credentials = credentials
        self.curlTemplate = curlTemplate
        self.validationCurl = validationCurl
        self.validationRule = validationRule
    }

    public static func suggestedEnvironmentName(for name: String) -> String {
        let normalized = name.uppercased().replacingOccurrences(of: #"[^A-Z0-9]+"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        guard !normalized.isEmpty else { return "API_KEY" }
        return (normalized.first?.isNumber == true ? "SERVICE_" : "") + normalized + "_API_KEY"
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
    private var pendingAuthorization: [UUID: String] = [:]

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
            var credentials = state.credentials
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
            if service.kind == .apiKey && credentials.isEmpty {
                credentials = [CredentialDraft(environmentVariable: service.environmentVariable)]
            }
            let curl = service.hasCurlTemplate ? (try keychain.read(account: KeychainStore.curlAccount(service.id))) : ""
            let validation = service.hasValidationRequest ? (try keychain.read(account: KeychainStore.validationAccount(service.id))) : ""
            return ServiceDraft(
                id: service.id,
                kind: service.kind,
                name: service.name,
                category: service.category,
                summary: service.summary,
                tags: service.tags,
                documentationURL: service.documentationURL,
                checkMode: service.checkMode,
                checkURL: service.checkURL,
                authentication: service.authentication,
                allowsLegacyCurlCheck: service.allowsLegacyCurlCheck,
                allowsIncomplete: service.credentialIDs.isEmpty,
                requiresBaseURL: service.requiresBaseURL,
                checkPath: service.checkPath,
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
            let existingService = state.services.first(where: { $0.id == serviceID })
            var credentialDrafts = draft.credentials
            if draft.allowsIncomplete {
                credentialDrafts.removeAll { item in item.secret.isEmpty && !state.credentials.contains(where: { $0.id == item.id && $0.serviceID == serviceID }) }
            }
            if draft.kind == .apiKey, credentialDrafts.isEmpty, !draft.allowsIncomplete {
                throw WhereKeyError.invalidInput("API Key 服务至少需要一个 Key")
            }
            guard draft.checkPath.isEmpty || (draft.checkPath.hasPrefix("/") && !draft.checkPath.hasPrefix("//") && !draft.checkPath.contains("..") && !draft.checkPath.contains("?") && !draft.checkPath.contains("#")) else {
                throw WhereKeyError.invalidInput("验证路径无效")
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
                guard alias != "__default", !alias.contains("}}") else { throw WhereKeyError.invalidInput("Key 别名包含保留字符") }
                guard aliases.insert(alias.lowercased()).inserted else { throw WhereKeyError.duplicate("同一服务中的 Key 别名不能重复") }
                let envName = item.environmentVariable.trimmingCharacters(in: .whitespacesAndNewlines)
                guard Self.isValidEnvironmentName(envName) else { throw WhereKeyError.invalidInput("环境变量名 \(envName) 无效") }
                if !state.credentials.contains(where: { $0.id == item.id && $0.serviceID == serviceID }) {
                    guard !state.credentials.contains(where: { $0.id == item.id }) else { throw WhereKeyError.invalidInput("Key 不属于此服务") }
                    guard !item.secret.isEmpty else { throw WhereKeyError.invalidInput("请输入 \(alias) 的 Key 值") }
                }
            }
            let baseVariable = draft.baseURLVariable.trimmingCharacters(in: .whitespacesAndNewlines)
            guard baseVariable.isEmpty || Self.isValidEnvironmentName(baseVariable) else {
                throw WhereKeyError.invalidInput("地址变量名无效")
            }
            guard baseVariable.isEmpty || !credentialDrafts.contains(where: { $0.environmentVariable.trimmingCharacters(in: .whitespacesAndNewlines) == baseVariable }) else {
                throw WhereKeyError.invalidInput("地址变量不能与 Key 变量重名")
            }
            for url in [draft.baseURL, draft.checkURL, draft.documentationURL] where !url.isEmpty {
                try Self.validatePublicURL(url)
            }
            if draft.authentication.kind == .header || draft.authentication.kind == .query {
                guard draft.authentication.fieldName.range(of: #"^[A-Za-z0-9_\-]+$"#, options: .regularExpression) != nil else {
                    throw WhereKeyError.invalidInput("请填写有效的鉴权字段名")
                }
            }
            var secretValues: [UUID: String] = [:]
            for item in credentialDrafts {
                secretValues[item.id] = item.secret.isEmpty
                    ? try keychain.read(account: KeychainStore.credentialAccount(item.id)) : item.secret
            }
            let publicFields = [name, draft.summary, draft.documentationURL, draft.baseURL, draft.checkURL,
                                draft.environmentVariable, draft.baseURLVariable, draft.authentication.fieldName,
                                draft.validationRule.acceptedStatusCodes, draft.validationRule.bodyContains,
                                draft.validationRule.jsonPath, draft.validationRule.jsonExpectedValue]
                + [draft.checkPath] + draft.tags + credentialDrafts.flatMap { [$0.alias, $0.environmentVariable] }
            guard !secretValues.values.contains(where: { secret in publicFields.contains(where: { $0.contains(secret) }) }) else {
                throw WhereKeyError.invalidInput("请将 Key 放入凭证字段，地址和说明不能包含 Key 明文")
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
            var keychainChanges: [String: String] = [:]
            for item in credentialDrafts {
                let existing = state.credentials.first(where: { $0.id == item.id })
                var suffix = existing?.maskedSuffix ?? item.existingSuffix
                if !item.secret.isEmpty {
                    keychainChanges[KeychainStore.credentialAccount(item.id)] = item.secret
                    suffix = item.secret.count > 8 ? String(item.secret.suffix(4)) : ""
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
            if !validationCurl.isEmpty {
                for item in credentialDrafts.sorted(by: { (secretValues[$0.id]?.count ?? 0) > (secretValues[$1.id]?.count ?? 0) }) {
                    if let secret = secretValues[item.id] {
                        validationCurl = validationCurl.replacingOccurrences(of: secret, with: item.isDefault ? "{{key}}" : "{{secret:\(item.alias)}}")
                    }
                }
                _ = try SafeCurl.parse(resolvePlaceholdersForValidation(validationCurl, drafts: credentialDrafts))
                keychainChanges[KeychainStore.validationAccount(serviceID)] = validationCurl
            }
            if draft.kind == .curl {
                keychainChanges[KeychainStore.curlAccount(serviceID)] = draft.curlTemplate
            }

            let defaultID = credentialDrafts.first(where: \.isDefault)?.id
            let record = ServiceRecord(
                id: serviceID,
                name: name,
                kind: draft.kind,
                category: draft.category,
                summary: draft.summary.trimmingCharacters(in: .whitespacesAndNewlines),
                tags: draft.tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.reduce(into: [String]()) { tags, tag in
                    if !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) { tags.append(tag) }
                },
                documentationURL: draft.documentationURL.trimmingCharacters(in: .whitespacesAndNewlines),
                checkMode: draft.checkMode,
                checkURL: draft.checkURL.trimmingCharacters(in: .whitespacesAndNewlines),
                authentication: draft.authentication,
                allowsLegacyCurlCheck: existingService?.allowsLegacyCurlCheck ?? false,
                requiresBaseURL: draft.requiresBaseURL,
                checkPath: draft.checkPath,
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
            var next = state
            next.services.removeAll { $0.id == serviceID }
            next.services.append(record)
            next.credentials.removeAll { $0.serviceID == serviceID }
            next.credentials.append(contentsOf: records)
            var previousSecrets: [String: String] = [:]
            for account in keychainChanges.keys {
                do { previousSecrets[account] = try keychain.read(account: account) }
                catch WhereKeyError.notFound { }
                catch WhereKeyError.keychain(let status) where status == -25300 { }
            }
            var written: [String] = []
            do {
                for (account, value) in keychainChanges {
                    try keychain.save(value, account: account)
                    written.append(account)
                }
                try metadataStore.save(next)
            } catch {
                for account in written {
                    if let old = previousSecrets[account] { try? keychain.save(old, account: account) }
                    else { try? keychain.delete(account: account) }
                }
                throw error
            }
            state = next
            if validationCurl.isEmpty { try? keychain.delete(account: KeychainStore.validationAccount(serviceID)) }
            if draft.kind != .curl { try? keychain.delete(account: KeychainStore.curlAccount(serviceID)) }
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
            state.services.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }.map { catalogRecord(for: $0) }
        }
    }

    // Directory and description reads must never touch Keychain. Curl templates
    // stay encrypted until an explicit edit or call actually needs the request.
    private func catalogRecord(for service: ServiceRecord) -> CatalogService {
                let credentials = state.credentials.filter { $0.serviceID == service.id }
                return CatalogService(
                    name: service.name,
                    kind: service.kind,
                    status: aggregateStatus(service: service, credentials: credentials),
                    baseURL: service.baseURL,
                    baseURLVariable: service.baseURLVariable,
                    credentials: credentials.map {
                        CatalogCredential(alias: $0.alias, environmentVariable: $0.environmentVariable, isDefault: service.defaultCredentialID == $0.id, status: $0.status)
                    },
                    redactedCurl: nil,
                    category: service.category,
                    summary: service.summary,
                    tags: service.tags,
                    documentationURL: service.documentationURL,
                    checkMode: service.checkMode,
                    setupMessage: service.setupMessage
                )
    }

    public func describe(service name: String) throws -> ServiceDescription {
        try lock.withLock {
            let service = try findService(name)
            let catalogService = catalogRecord(for: service)
            let projects = projectPaths(for: service.id, credentialID: nil)
            return ServiceDescription(service: catalogService, usageProjects: projects)
        }
    }

    public func prepareRun(service name: String, keyAlias: String?, cwd: String) throws -> PreparedRun {
        try lock.withLock {
            let service = try findService(name)
            if let missing = service.setupMessage { throw WhereKeyError.invalidInput("\(service.name)：\(missing)，请在 WhereKey 中补充后再运行") }
            let credential = try selectCredential(for: service, alias: keyAlias)
            guard let credential else {
                throw WhereKeyError.invalidInput("该 curl 服务没有可注入的 Key，请使用 wherekey call")
            }
            let secret: String
            do { secret = try keychain.read(account: KeychainStore.credentialAccount(credential.id)) }
            catch {
                _ = authorizationResult(error, service: service, credential: credential)
                throw error
            }
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
            let secrets = try secrets(for: service, selectedAlias: keyAlias, template: template)
            let credential = try selectCredential(for: service, alias: keyAlias)
            let result = try validator.execute(template: template, secrets: secrets, rule: service.validationRule, returnBody: true)
            try recordUsage(path: cwd, service: service, credential: credential)
            updateStatus(serviceID: service.id, credentialID: credential?.id, result: result)
            return result
        }
    }

    public func check(service name: String, keyAlias: String?, automatic: Bool = false, readOnly: Bool = false) throws -> CheckResult {
        try lock.withLock {
            let service = try findService(name)
            let credential = try selectCredential(for: service, alias: keyAlias)
            func skipped(_ message: String) -> CheckResult {
                let result = CheckResult(status: .unchecked, httpStatus: nil, elapsedMilliseconds: 0, message: message)
                updateStatus(serviceID: service.id, credentialID: credential?.id, result: result, performed: false)
                return result
            }
            if let missing = service.setupMessage { return skipped(missing) }
            guard service.checkMode != .disabled else { return skipped("已关闭有效性检查；仍可使用已保存的凭证") }
            if automatic && service.checkMode != .automatic { return skipped("此服务仅手动检查") }
            do {
            let template: String
            if service.hasValidationRequest {
                template = try keychain.read(account: KeychainStore.validationAccount(service.id))
            } else if let generated = automaticValidationTemplate(for: service) {
                template = generated
            } else if !automatic && !readOnly && service.kind == .curl && service.allowsLegacyCurlCheck {
                template = try keychain.read(account: KeychainStore.curlAccount(service.id))
            } else {
                return skipped("未配置验证请求；已保存，尚未验证")
            }
            guard !(automatic || readOnly) || SafeCurl.isReadOnly(template) else { return skipped("自动或批量检查只执行独立 GET / HEAD 验证请求，请单独手动检查此请求") }
            let secrets = try secrets(for: service, selectedAlias: keyAlias, template: template)
            let result = try validator.execute(template: template, secrets: secrets, rule: service.validationRule, returnBody: false)
            updateStatus(serviceID: service.id, credentialID: credential?.id, result: result)
            return result
            } catch {
                if let result = authorizationResult(error, service: service, credential: credential) { return result }
                throw error
            }
        }
    }

    private func authorizationResult(_ error: Error, service: ServiceRecord, credential: CredentialRecord?) -> CheckResult? {
        guard case WhereKeyError.authorizationRequired(let account) = error else { return nil }
        pendingAuthorization[service.id] = account
        let result = CheckResult(status: .authorizationRequired, httpStatus: nil, elapsedMilliseconds: 0, message: error.localizedDescription)
        updateStatus(serviceID: service.id, credentialID: credential?.id, result: result, performed: false)
        return result
    }

    /// Only a deliberate click in the app may show a system authorization UI.
    /// One click authorizes one item belonging to this service, without retries.
    public func authorize(service name: String, keyAlias: String? = nil) throws {
        let target: (UUID, String) = try lock.withLock {
            let service = try findService(name)
            if let account = pendingAuthorization[service.id] { return (service.id, account) }
            if let credential = try selectCredential(for: service, alias: keyAlias) {
                return (service.id, KeychainStore.credentialAccount(credential.id))
            }
            if service.hasCurlTemplate { return (service.id, KeychainStore.curlAccount(service.id)) }
            throw WhereKeyError.invalidInput("此服务没有需要授权的凭证")
        }
        _ = try keychain.read(account: target.1, interactive: true)
        _ = lock.withLock { pendingAuthorization.removeValue(forKey: target.0) }
    }

    public func checkAll() -> [(String, CheckResult)] {
        let names = lock.withLock { state.services.map(\.name) }
        return names.map { name in
            do { return (name, try check(service: name, keyAlias: nil, readOnly: true)) }
            catch { return (name, CheckResult(status: .unavailable, httpStatus: nil, elapsedMilliseconds: 0, message: error.localizedDescription)) }
        }
    }

    public func checkAllAPIKeys() -> [(String, String, CheckResult)] {
        let targets: [(String, String)] = lock.withLock {
            state.services
                .filter { $0.checkMode == .automatic }
                .flatMap { service in
                    let selected = try? selectCredential(for: service, alias: nil)
                    return [(service.name, selected?.alias ?? "")]
                }
        }
        return targets.map { serviceName, alias in
            do { return (serviceName, alias, try check(service: serviceName, keyAlias: alias, automatic: true)) }
            catch {
                return (
                    serviceName,
                    alias,
                    CheckResult(status: .unavailable, httpStatus: nil, elapsedMilliseconds: 0, message: error.localizedDescription)
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

    private func secrets(for service: ServiceRecord, selectedAlias: String?, template: String) throws -> [String: String] {
        let credentials = state.credentials.filter { $0.serviceID == service.id }
        var values: [String: String] = [:]
        let selected = try selectCredential(for: service, alias: selectedAlias)
        let usesDefault = template.contains("{{key}}") || template.contains("{{key:url}}")
        for credential in credentials where template.contains("{{secret:\(credential.alias)}}") || (usesDefault && credential.id == selected?.id) {
            values[credential.alias] = try keychain.read(account: KeychainStore.credentialAccount(credential.id))
        }
        if usesDefault, let selected, let value = values[selected.alias] {
            values["__default"] = value
        }
        return values
    }

    private func automaticValidationTemplate(for service: ServiceRecord) -> String? {
        let checkURL = !service.checkURL.isEmpty ? service.checkURL : (!service.checkPath.isEmpty && !service.baseURL.isEmpty ? service.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + service.checkPath : "")
        if !checkURL.isEmpty, service.authentication.kind != .providerPreset {
            var url = checkURL
            var headers: [String] = []
            switch service.authentication.kind {
            case .bearer: headers = ["Authorization: Bearer {{key}}"]
            case .header: headers = ["\(service.authentication.fieldName): {{key}}"]
            case .query:
                guard var components = URLComponents(string: url) else { return nil }
                var items = (components.queryItems ?? []).filter { $0.name != service.authentication.fieldName }
                items.append(URLQueryItem(name: service.authentication.fieldName, value: "WHEREKEY_QUERY_PLACEHOLDER"))
                components.queryItems = items
                guard let encoded = components.url?.absoluteString else { return nil }
                url = encoded.replacingOccurrences(of: "WHEREKEY_QUERY_PLACEHOLDER", with: "{{key:url}}")
            case .none: break
            case .providerPreset: return nil
            }
            return (["curl \(SafeCurl.quote(url))"] + headers.map { "-H \(SafeCurl.quote($0))" }).joined(separator: " ")
        }
        guard service.authentication.kind == .providerPreset else { return nil }
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
            return nil
        }

        return (["curl \(SafeCurl.quote(service.checkURL.isEmpty ? url : service.checkURL))"] + headers.map { "-H \(SafeCurl.quote($0))" }).joined(separator: " ")
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

    private func updateStatus(serviceID: UUID, credentialID: UUID?, result: CheckResult, performed: Bool = true) {
        let now = Date()
        if let index = state.services.firstIndex(where: { $0.id == serviceID }) {
            state.services[index].curlStatus = result.status
            state.services[index].lastCheckedAt = performed ? now : nil
        }
        if let credentialID, let index = state.credentials.firstIndex(where: { $0.id == credentialID }) {
            state.credentials[index].status = result.status
            state.credentials[index].lastCheckedAt = performed ? now : nil
        }
        try? metadataStore.save(state)
    }

    private func aggregateStatus(service: ServiceRecord, credentials: [CredentialRecord]) -> HealthStatus {
        if service.kind == .curl { return service.curlStatus }
        guard !credentials.isEmpty else { return .unchecked }
        if let defaultID = service.defaultCredentialID, let value = credentials.first(where: { $0.id == defaultID }) { return value.status }
        return credentials[0].status
    }

    private func resolvePlaceholdersForValidation(_ template: String, drafts: [CredentialDraft]) -> String {
        var value = template
        for draft in drafts {
            value = value.replacingOccurrences(of: "{{secret:\(draft.alias)}}", with: "placeholder")
        }
        return value.replacingOccurrences(of: "{{key:url}}", with: "placeholder").replacingOccurrences(of: "{{key}}", with: "placeholder")
    }

    private static func validatePublicURL(_ value: String) throws {
        guard let c = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(c.scheme?.lowercased() ?? ""), c.host?.isEmpty == false,
              c.user == nil, c.password == nil else {
            throw WhereKeyError.invalidInput("地址必须是无内嵌账号密码的 http/https URL")
        }
        let secretNames = ["key", "api_key", "apikey", "token", "access_token", "secret", "password"]
        guard !(c.queryItems ?? []).contains(where: { secretNames.contains($0.name.lowercased()) && !($0.value ?? "").isEmpty }) else {
            throw WhereKeyError.invalidInput("地址不能包含 Key 或 Token 参数，请改用鉴权配置或验证 curl")
        }
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
