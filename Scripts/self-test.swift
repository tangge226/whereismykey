import Foundation
import LocalAuthentication
import Security
@testable import WhereKeyCore

final class MemorySecrets: SecretStoring {
    var values: [String: String] = [:]
    var readAccounts: [String] = []
    var interactiveReadAccounts: [String] = []
    var lockedAccounts = Set<String>()
    func save(_ value: String, account: String) throws { values[account] = value }
    func read(account: String) throws -> String {
        readAccounts.append(account)
        if lockedAccounts.contains(account) { throw WhereKeyError.authorizationRequired(account) }
        guard let value = values[account] else { throw WhereKeyError.notFound("missing") }
        return value
    }
    func read(account: String, interactive: Bool) throws -> String {
        if interactive { interactiveReadAccounts.append(account); lockedAccounts.remove(account) }
        return try read(account: account)
    }
    func delete(account: String) throws { values.removeValue(forKey: account) }
}

var assertionCount = 0
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    assertionCount += 1
    if !condition() { fatalError(message) }
}

func requireThrows(_ message: String, _ body: () throws -> Void) {
    do { try body() }
    catch { assertionCount += 1; return }
    fatalError(message)
}

// Check expanded credential values without spawning curl or reading a file.
for (option, value) in [("--header", "@/tmp/fixture"), ("--data", "@/tmp/fixture"),
                        ("--data-binary", "@/tmp/fixture"), ("--json", "@/tmp/fixture"),
                        ("--data-urlencode", "field@/tmp/fixture")] {
    requireThrows("展开后的凭证绕过了本地文件限制") {
        try SafeCurl.validateExpandedArguments([option, value, "https://example.test"])
    }
}
try SafeCurl.validateExpandedArguments(["--header", "X-Key: @literal", "--data-raw", "@literal", "https://example.test"])

// Pure parser regressions: no malicious fixture is executed or reads a file.
for option in ["--config=/tmp/fixture", "-K/tmp/fixture", "--conf /tmp/fixture",
               "--output=/tmp/fixture", "-o/tmp/fixture", "--upload-file=/tmp/fixture", "-T/tmp/fixture",
               "--trace=/tmp/fixture", "--write-out=@/tmp/fixture", "--cookie-jar=/tmp/fixture",
               "--netrc", "--cacert=/tmp/fixture", "--cert /tmp/fixture", "--key /tmp/fixture",
               "--form 'field=@/tmp/fixture'", "-F'field=</tmp/fixture'",
               "--data=@/tmp/fixture", "-d@/tmp/fixture", "--data-binary=@/tmp/fixture",
               "--data-urlencode 'field@/tmp/fixture'", "--json=@/tmp/fixture",
               "--header=@/tmp/fixture", "-H@/tmp/fixture", "--url=file:///tmp/fixture",
               "--proto=all", "--proto-redir=file", "--next", "--location-trusted", "-sSo/tmp/fixture"] {
    requireThrows("curl 参数绕过了本地文件/协议限制") { _ = try SafeCurl.parse("curl \(option) https://example.test") }
}
let attachedCurl = try SafeCurl.parse("curl -XPOST --header='Content-Type: application/json' -d'{\"ok\":true}' https://example.test")
require(attachedCurl.arguments.contains("--request") && attachedCurl.arguments.contains("--data"), "curl 参数未规范化")
let bundledCurl = try SafeCurl.parse("curl -fsSL https://example.test")
require(bundledCurl.arguments.contains("--fail") && bundledCurl.arguments.contains("--location"), "常见短 flag 组合不兼容")
let silentCurl = try SafeCurl.parse("curl -sS https://example.test")
require(silentCurl.arguments.contains("--silent") && silentCurl.arguments.contains("--show-error"), "-sS 不兼容")
require(!SafeCurl.isReadOnly("curl -XPOST https://example.test") && !SafeCurl.isReadOnly("curl --request=POST https://example.test"), "拼接参数绕过了只读判定")
require(SafeCurl.isReadOnly("curl -XGET -H'X-Test: literal' https://example.test"), "合法 GET 规范化后无法验证")
let literalBody = try SafeCurl.parse("curl --form-string='field=@literal' --data-urlencode='email=user@example.test' https://example.test")
require(literalBody.arguments.contains("field=@literal") && literalBody.arguments.contains("email=user@example.test"), "合法字面量表单不兼容")

let parsed = try SafeCurl.parse("curl -H 'Authorization: Bearer abc' https://example.test")
require(parsed.arguments.contains("Authorization: Bearer abc"), "curl 引号解析失败")
do {
    _ = try SafeCurl.parse("curl https://example.test | sh")
    fatalError("未拒绝 shell 管道")
} catch {}

if let testURL = ProcessInfo.processInfo.environment["WHEREKEY_TEST_URL"] {
    let result = try CurlValidator().execute(template: "curl \(testURL)", secrets: [:], rule: ValidationRule(), returnBody: true)
    require(result.status == .valid, "本地 curl 检查失败：\(result.message)")
    require(result.httpStatus == 200, "本地 curl 状态码错误")

    let apiDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("WhereKeyAPICheck-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: apiDirectory) }
    let apiRepository = try WhereKeyRepository(
        metadataStore: MetadataStore(directoryURL: apiDirectory),
        keychain: MemorySecrets()
    )
    let apiDraft = ServiceDraft(
        kind: .apiKey,
        name: "Automatic API Check",
        checkMode: .automatic,
        checkURL: testURL,
        authentication: Authentication(kind: .bearer),
        environmentVariable: "TEST_API_KEY",
        baseURL: testURL,
        baseURLVariable: "TEST_BASE_URL",
        credentials: [CredentialDraft(environmentVariable: "TEST_API_KEY", secret: "test-secret")]
    )
    try apiRepository.save(apiDraft)
    let automaticResult = try apiRepository.check(service: "Automatic API Check", keyAlias: nil)
    require(automaticResult.status == .valid, "未自动生成 API Key 验证请求：\(automaticResult.message)")
    require(apiRepository.catalog()[0].status == .valid, "自动检查结果未保存")
}

let server = IPCServer { request in
    IPCResponse(ok: request.action == "catalog", catalog: [])
}
try server.start()
defer { server.stop() }
let ipcResponse = try IPCClient().send(IPCRequest(action: "catalog"))
require(ipcResponse.ok, "IPC 往返失败")
let rejectedResponse = try IPCClient().send(IPCRequest(action: "unknown"))
require(!rejectedResponse.ok, "IPC 业务错误不应伪装成连接失败")
require(WhereKeyError.keychain(-25293).localizedDescription.contains("重新打开"), "Keychain 授权错误提示不清晰")

let deepSeekSecret = "sk-deepseek-self-test-123456"
let deepSeekImports = NoteImportParser.parse("""
DeepSeek 官网
key: \(deepSeekSecret)
""")
require(deepSeekImports.count == 1, "DeepSeek 笔记识别失败")
require(deepSeekImports[0].draft.baseURL == "https://api.deepseek.com", "DeepSeek API 地址补全失败")
require(deepSeekImports[0].draft.credentials[0].environmentVariable == "DEEPSEEK_API_KEY", "DeepSeek 环境变量补全失败")
require(!deepSeekImports[0].sourcePreview.contains(deepSeekSecret), "导入预览泄露 Key")

let mixedImports = NoteImportParser.parse("""
OpenAI
OPENAI_API_KEY=sk-proj-openai-self-test-123456

内网 ASR
URL: http://10.0.0.8:9000/v1/audio/transcriptions
token: internal-asr-token-123456

内网 Embedding
http://10.0.0.9:8000/v1/embeddings
API_KEY: embedding-token-123456
""")
require(mixedImports.count == 3, "混合笔记拆分失败")
require(mixedImports[1].draft.name == "内网 ASR", "内网 ASR 名称识别失败")
require(mixedImports[2].draft.baseURL.contains("/v1/embeddings"), "Embedding URL 识别失败")

let bareInternalImports = NoteImportParser.parse("""
内网 ASR
10.0.0.8:9000/v1/audio/transcriptions
raw-token-1234567890
""")
require(bareInternalImports.count == 1, "无协议内网地址识别失败")
require(bareInternalImports[0].draft.baseURL == "http://10.0.0.8:9000/v1/audio/transcriptions", "内网地址未自动补全 http")
require(bareInternalImports[0].draft.credentials[0].secret == "raw-token-1234567890", "裸 Token 识别失败")

let azureImports = NoteImportParser.parse("""
Azure OpenAI
AZURE_OPENAI_API_KEY=azure-key-1234567890
""")
require(azureImports.count == 1, "Azure OpenAI 识别失败")
require(azureImports[0].draft.baseURL.isEmpty, "Azure OpenAI 不应自动套用公共 OpenAI 地址")

let curlImportSecret = "curl-self-test-secret-123456"
let curlImports = NoteImportParser.parse("""
内网搜索
curl http://10.0.0.5:4000/search -H 'Authorization: Bearer \(curlImportSecret)' -d '{"q":"test"}'
""")
require(curlImports.count == 1 && curlImports[0].draft.kind == .curl, "curl 服务识别失败")
require(curlImports[0].draft.curlTemplate.contains("{{secret:default}}"), "curl Key 提取失败")
require(!curlImports[0].sourcePreview.contains(curlImportSecret), "curl 导入预览泄露 Key")

let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WhereKeySelfTest-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: directory) }
let repository = try WhereKeyRepository(metadataStore: MetadataStore(directoryURL: directory), keychain: MemorySecrets())
let importedServiceID = try repository.save(deepSeekImports[0].draft)
let secret = "do-not-persist-this"
let draft = ServiceDraft(name: "Example", credentials: [CredentialDraft(alias: "default", environmentVariable: "EXAMPLE_KEY", secret: secret)])
let serviceID = try repository.save(draft)
let prepared = try repository.prepareRun(service: "Example", keyAlias: nil, cwd: directory.path)
require(prepared.environment["EXAMPLE_KEY"] == secret, "默认 Key 注入失败")
let metadata = try String(contentsOf: directory.appendingPathComponent("metadata.json"), encoding: .utf8)
require(!metadata.contains(secret), "秘密写入了元数据")
require(!metadata.contains(deepSeekSecret), "批量导入 Key 写入了元数据")
try repository.deleteService(serviceID)
try repository.deleteService(importedServiceID)
require(repository.snapshot().services.isEmpty, "服务删除失败")
require(repository.snapshot().usages.count == 1, "删除服务后使用记录未保留")

// Custom services have no required endpoint and retain metadata across reloads.
let customSecrets = MemorySecrets()
let customDirectory = directory.appendingPathComponent("custom")
let customStore = MetadataStore(directoryURL: customDirectory)
let custom = try WhereKeyRepository(metadataStore: customStore, keychain: customSecrets)
let customSecret = "fixture-tucui-primary-secret"
let customID = try custom.save(ServiceDraft(
    name: "Tucui", category: .custom, summary: "知识查询", tags: ["自建", " 知识库 ", "自建"],
    documentationURL: "https://docs.example.test/tucui",
    credentials: [
        CredentialDraft(alias: "production", environmentVariable: "TUCUI_API_KEY", secret: customSecret),
        CredentialDraft(alias: "test", environmentVariable: "TUCUI_API_KEY", secret: "fixture-tucui-test-secret", isDefault: false),
    ]
))
let unchecked = try custom.check(service: "Tucui", keyAlias: nil)
require(unchecked.status == .unchecked, "无验证地址的自定义服务被误报失效")
require(custom.snapshot().services[0].lastCheckedAt == nil, "没有请求时不应记录检查时间")
let customPrepared = try custom.prepareRun(service: "Tucui", keyAlias: nil, cwd: directory.path)
require(customPrepared.environment["TUCUI_API_KEY"] == customSecret, "Tucui 默认 Key 注入失败")
let testPrepared = try custom.prepareRun(service: "Tucui", keyAlias: "test", cwd: directory.path)
require(testPrepared.environment["TUCUI_API_KEY"] == "fixture-tucui-test-secret", "自定义 Key 别名不兼容")
let reloaded = try WhereKeyRepository(metadataStore: customStore, keychain: customSecrets)
let service = reloaded.snapshot().services[0]
require(service.id == customID && service.summary == "知识查询" && service.tags == ["自建", "知识库"], "自定义元数据未正确保存")
require(service.matches(search: "知识") && service.matches(search: "自建服务"), "用途和分类不可搜索")
var edit = try reloaded.draft(for: customID)
require(edit.credentials.allSatisfy { $0.secret.isEmpty }, "编辑草稿不应包含 Key 明文")
edit.summary = "知识检索与查询"
try reloaded.save(edit)
let editedPrepared = try reloaded.prepareRun(service: "Tucui", keyAlias: nil, cwd: directory.path)
require(editedPrepared.environment["TUCUI_API_KEY"] == customSecret, "仅编辑说明丢失原 Key")
let catalogText = String(decoding: try JSONEncoder().encode(reloaded.catalog()), as: UTF8.self)
let customMetadata = try String(contentsOf: customStore.fileURL, encoding: .utf8)
require(catalogText.contains("知识检索与查询") && !catalogText.contains(customSecret), "目录说明或脱敏错误")
require(!customMetadata.contains(customSecret), "自定义服务 Key 泄露到 metadata")
var leakingDraft = edit
leakingDraft.summary = customSecret
requireThrows("说明中允许写入 Key 明文") { try reloaded.save(leakingDraft) }
var invalidDraft = edit
invalidDraft.credentials[0].secret = "fixture-replacement-secret"
invalidDraft.validationCurl = "curl https://example.test | sh"
requireThrows("无效检查请求被接受") { try reloaded.save(invalidDraft) }
let afterRejected = try reloaded.prepareRun(service: "Tucui", keyAlias: nil, cwd: directory.path)
require(afterRejected.environment["TUCUI_API_KEY"] == customSecret, "保存失败破坏原 Key")

let rollbackDirectory = directory.appendingPathComponent("rollback")
let rollbackStore = MetadataStore(directoryURL: rollbackDirectory)
let rollbackSecrets = MemorySecrets()
let rollbackRepository = try WhereKeyRepository(metadataStore: rollbackStore, keychain: rollbackSecrets)
let rollbackID = try rollbackRepository.save(ServiceDraft(name: "Rollback", credentials: [CredentialDraft(environmentVariable: "ROLLBACK_KEY", secret: "fixture-original-secret")]))
let beforeFailedSave = rollbackRepository.snapshot()
var rollbackDraft = try rollbackRepository.draft(for: rollbackID)
rollbackDraft.credentials[0].secret = "fixture-updated-secret"
let holdingDirectory = directory.appendingPathComponent("rollback-holding")
try FileManager.default.moveItem(at: rollbackDirectory, to: holdingDirectory)
try Data("blocks metadata directory creation".utf8).write(to: rollbackDirectory)
requireThrows("元数据写入失败应中止保存") { try rollbackRepository.save(rollbackDraft) }
require(rollbackRepository.snapshot() == beforeFailedSave, "元数据写入失败更改了内存目录")
require(rollbackSecrets.values[KeychainStore.credentialAccount(rollbackDraft.credentials[0].id)] == "fixture-original-secret", "元数据写入失败未回滚 Key")
try FileManager.default.removeItem(at: rollbackDirectory)
try FileManager.default.moveItem(at: holdingDirectory, to: rollbackDirectory)

for note in ["Tucui\nTUCUI_API_KEY=alphabeticcredential", "Tucui\nTUCUI_TOKEN='fixture +/?&= secret;'", "Tucui\nkey: abc"] {
    let candidates = NoteImportParser.parse(note)
    require(candidates.count == 1, "自定义 Key 导入未生成唯一候选项")
    require(candidates[0].draft.credentials.count == 1, "自定义 Key 被截断成多个凭证")
    require(candidates[0].draft.name == "Tucui" && candidates[0].draft.checkMode == .manual, "自定义导入套用了厂商模板")
    require(!candidates[0].sourcePreview.contains(candidates[0].draft.credentials[0].secret), "自定义导入预览泄露 Key")
}
let quotedImport = NoteImportParser.parse("Tucui\nTUCUI_TOKEN='fixture +/?&= secret;'")[0]
require(quotedImport.draft.credentials[0].secret == "fixture +/?&= secret;", "导入更改了自定义 Key 内容")
require(quotedImport.draft.credentials[0].environmentVariable == "TUCUI_TOKEN", "导入丢失自定义变量名")
let lowerCaseImport = NoteImportParser.parse("Tucui\ntucui_token=lowercasecredential")[0]
require(lowerCaseImport.draft.credentials[0].environmentVariable == "tucui_token", "自定义变量名大小写被更改")
let orderedImport = NoteImportParser.parse("Tucui\nTUCUI_API_KEY=firstcredential\nTUCUI_API_KEY='second credential'")[0]
require(orderedImport.draft.credentials.count == 2 && orderedImport.draft.credentials[0].secret == "firstcredential", "引号格式改变了默认 Key 顺序")
require(NoteImportParser.parse("Tucui\nkey: abc")[0].draft.credentials[0].environmentVariable == "TUCUI_API_KEY", "未按服务名建议变量")
require(deepSeekImports[0].draft.checkMode == .automatic && deepSeekImports[0].draft.category == .ai, "厂商预设未保留自动检查")

if let testURL = ProcessInfo.processInfo.environment["WHEREKEY_TEST_URL"] {
    let fixtureBase = String(testURL.dropLast())
    for (name, auth, path, value) in [
        ("Header", Authentication(kind: .header, fieldName: "X-Tucui-Key"), "/header", "fixture-header-secret"),
        ("Query", Authentication(kind: .query, fieldName: "api_key"), "/query", "fixture +/?&='secret"),
        ("Bearer", Authentication(kind: .bearer), "/bearer", "fixture ' quoted secret"),
        ("Public", Authentication(kind: .none), "/", "fixture-unused-secret"),
    ] {
        try custom.save(ServiceDraft(name: name, checkMode: .automatic, checkURL: fixtureBase + path, authentication: auth,
                                     credentials: [CredentialDraft(environmentVariable: "FIXTURE_KEY", secret: value)]))
        let result = try custom.check(service: name, keyAlias: nil, automatic: true)
        require(result.status == .valid, "\(name) 自定义鉴权验证失败：\(result.message)")
    }
    try custom.save(ServiceDraft(name: "Unknown", checkMode: .automatic, baseURL: fixtureBase + "/status/401",
                                 credentials: [CredentialDraft(environmentVariable: "UNKNOWN_KEY", secret: "fixture-unknown-secret")]))
    let unknownResult = try custom.check(service: "Unknown", keyAlias: nil, automatic: true)
    require(unknownResult.status == .unchecked, "未知服务仍默认使用 Bearer 请求基础地址")
    try custom.save(ServiceDraft(name: "Disabled", checkMode: .disabled,
                                 credentials: [CredentialDraft(environmentVariable: "DISABLED_KEY", secret: "fixture-disabled-secret")],
                                 validationCurl: "curl '\(fixtureBase)/status/401'"))
    let disabledResult = try custom.check(service: "Disabled", keyAlias: nil)
    require(disabledResult.status == .unchecked, "关闭检查仍发出了鉴权请求")
    let checks = custom.checkAllAPIKeys()
    require(!checks.contains { $0.0 == "Tucui" || $0.0 == "Disabled" }, "启动检查包含手动或禁用服务")

    let curlID = try custom.save(ServiceDraft(kind: .curl, name: "Business POST", checkMode: .automatic,
                                            credentials: [], curlTemplate: "curl -X POST '\(testURL)'"))
    let autoCurl = try custom.check(service: "Business POST", keyAlias: nil, automatic: true)
    let manualCurl = try custom.check(service: "Business POST", keyAlias: nil)
    require(autoCurl.status == .unchecked && manualCurl.status == .unchecked, "新 curl 服务检查重放了业务请求")
    let callResult = try custom.call(service: "Business POST", keyAlias: nil, cwd: directory.path)
    require(callResult.httpStatus == 201 && callResult.status == .valid, "原有 curl call 调用不兼容")
    var curlEdit = try custom.draft(for: curlID)
    curlEdit.validationCurl = "curl '\(testURL)'"
    try custom.save(curlEdit)
    let separateCheck = try custom.check(service: "Business POST", keyAlias: nil, automatic: true)
    require(separateCheck.httpStatus == 200, "未使用独立 GET 检查请求")
    curlEdit.validationCurl = "curl -X POST '\(testURL)'"
    try custom.save(curlEdit)
    let postCheck = try custom.check(service: "Business POST", keyAlias: nil, automatic: true)
    require(postCheck.status == .unchecked, "自动检查执行了 POST 验证请求")
    let batchPostCheck = custom.checkAll().first { $0.0 == "Business POST" }
    require(batchPostCheck?.1.status == .unchecked, "批量检查执行了 POST 验证请求")

    for (code, expected) in [(401, HealthStatus.invalid), (403, .forbidden), (429, .rateLimited), (500, .failed)] {
        let result = try CurlValidator().execute(template: "curl '\(fixtureBase)/status/\(code)'", secrets: [:], rule: ValidationRule(), returnBody: false)
        require(result.status == expected && result.status.isFailure, "HTTP \(code) 检查状态不准确")
    }
    let networkResult = try CurlValidator().execute(template: "curl 'http://127.0.0.1:1'", secrets: [:], rule: ValidationRule(timeoutSeconds: 1), returnBody: false)
    require(networkResult.status == .unavailable, "连接失败被误判为 Key 失效")
    let echoSecret = "fixture +/?&='secret"
    let echoResult = try CurlValidator().execute(template: "curl '\(fixtureBase)/query?api_key={{key:url}}'", secrets: ["__default": echoSecret], rule: ValidationRule(), returnBody: true)
    require(echoResult.status == .valid && !echoResult.responsePreview.contains(SafeCurl.encodedQuerySecret(echoSecret)), "响应泄露 URL 编码后的 Key")
}

// Migrate a genuine v1-shaped fixture; no real user data or Keychain is opened.
let legacyDirectory = directory.appendingPathComponent("legacy")
let legacyStore = MetadataStore(directoryURL: legacyDirectory)
let legacySecrets = MemorySecrets()
let legacyID = UUID(), legacyKeyID = UUID(), legacyCurlID = UUID()
let legacyProject = ProjectRecord(path: directory.path)
let legacyService = ServiceRecord(id: legacyID, name: "Legacy OpenAI", kind: .apiKey, environmentVariable: "OPENAI_API_KEY",
                                  baseURL: "https://api.openai.com/v1", baseURLVariable: "OPENAI_BASE_URL",
                                  credentialIDs: [legacyKeyID], defaultCredentialID: legacyKeyID)
let legacyCurl = ServiceRecord(id: legacyCurlID, name: "Legacy curl", kind: .curl, hasCurlTemplate: true)
let legacyKey = CredentialRecord(id: legacyKeyID, serviceID: legacyID, alias: "production", environmentVariable: "OPENAI_API_KEY", maskedSuffix: "cret")
let legacyUsage = UsageRecord(projectID: legacyProject.id, serviceID: legacyID, credentialID: legacyKeyID,
                              serviceNameSnapshot: legacyService.name, credentialAliasSnapshot: "production")
let legacyState = MetadataState(schemaVersion: 1, services: [legacyService, legacyCurl], credentials: [legacyKey], projects: [legacyProject], usages: [legacyUsage])
let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601
var legacyJSON = try JSONSerialization.jsonObject(with: encoder.encode(legacyState)) as! [String: Any]
var legacyServices = legacyJSON["services"] as! [[String: Any]]
for index in legacyServices.indices {
    for key in ["category", "summary", "tags", "documentationURL", "checkMode", "checkURL", "authentication", "allowsLegacyCurlCheck"] {
        legacyServices[index].removeValue(forKey: key)
    }
}
legacyJSON["services"] = legacyServices
let legacyData = try JSONSerialization.data(withJSONObject: legacyJSON, options: .sortedKeys)
try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
try legacyData.write(to: legacyStore.fileURL)
try legacySecrets.save("fixture-legacy-secret", account: KeychainStore.credentialAccount(legacyKeyID))
let legacyURL = ProcessInfo.processInfo.environment["WHEREKEY_TEST_URL"] ?? "http://127.0.0.1:1/"
try legacySecrets.save("curl '\(legacyURL)'", account: KeychainStore.curlAccount(legacyCurlID))
let migrated = try WhereKeyRepository(metadataStore: legacyStore, keychain: legacySecrets)
require(migrated.snapshot().schemaVersion == 2, "v1 未升级为 v2")
require(migrated.snapshot().services[0].id == legacyID && migrated.snapshot().credentials[0].id == legacyKeyID, "迁移更改了凭证引用")
require(migrated.snapshot().services[0].checkMode == .automatic, "旧 API Key 未保留厂商自动检查")
require(migrated.snapshot().services[1].allowsLegacyCurlCheck, "旧 curl 手动检查兼容标志丢失")
require(migrated.snapshot().usages[0].id == legacyUsage.id && migrated.snapshot().projects[0].id == legacyProject.id, "迁移丢失项目使用记录")
let backup = try Data(contentsOf: legacyDirectory.appendingPathComponent("metadata.v1.backup.json"))
require(backup == legacyData, "原版元数据备份不完整")
let backupAttributes = try FileManager.default.attributesOfItem(atPath: legacyDirectory.appendingPathComponent("metadata.v1.backup.json").path)
require((backupAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "备份权限不是仅当前用户读写")
let migratedPrepared = try migrated.prepareRun(service: "Legacy OpenAI", keyAlias: "production", cwd: directory.path)
require(migratedPrepared.environment["OPENAI_API_KEY"] == "fixture-legacy-secret" && migratedPrepared.environment["OPENAI_BASE_URL"] == "https://api.openai.com/v1", "迁移破坏旧环境注入")
// Use an isolated repository so batch checking never touches the public model
// provider fixture above. A legacy POST is never read or sent in batch mode.
let batchStore = MetadataStore(directoryURL: directory.appendingPathComponent("batch-check"))
let batchID = UUID()
let batchService = ServiceRecord(id: batchID, name: "Legacy business POST", kind: .curl,
                                checkMode: .manual, allowsLegacyCurlCheck: true, hasCurlTemplate: true)
try batchStore.save(MetadataState(services: [batchService]))
let batchSecrets = MemorySecrets()
try batchSecrets.save("curl -X POST '\(legacyURL)'", account: KeychainStore.curlAccount(batchID))
let batchRepository = try WhereKeyRepository(metadataStore: batchStore, keychain: batchSecrets)
let batchResults = batchRepository.checkAll()
require(batchResults.count == 1 && batchResults[0].1.status == .unchecked, "旧业务 curl 未在批量检查中跳过")
require(batchSecrets.readAccounts.isEmpty, "批量检查读取了旧业务 curl，可能重放业务请求")
if ProcessInfo.processInfo.environment["WHEREKEY_TEST_URL"] != nil {
    let explicitLegacyPOST = try batchRepository.check(service: "Legacy business POST", keyAlias: nil)
    require(explicitLegacyPOST.httpStatus == 201, "单独显式检查旧 POST 的兼容行为改变")
}
if ProcessInfo.processInfo.environment["WHEREKEY_TEST_URL"] != nil {
    let oldCurlResult = try migrated.check(service: "Legacy curl", keyAlias: nil)
    require(oldCurlResult.status == .valid, "旧 curl 手动检查不兼容")
}
_ = try legacyStore.load()
let repeatedBackup = try Data(contentsOf: legacyDirectory.appendingPathComponent("metadata.v1.backup.json"))
require(repeatedBackup == legacyData, "重复加载覆盖了 v1 备份")
let unsupportedStore = MetadataStore(directoryURL: directory.appendingPathComponent("unsupported"))
try FileManager.default.createDirectory(at: unsupportedStore.directoryURL, withIntermediateDirectories: true)
let futureData = Data("{\"schemaVersion\":99}".utf8)
try futureData.write(to: unsupportedStore.fileURL)
requireThrows("未来版本应拒绝加载") { _ = try unsupportedStore.load() }
let unchangedFutureData = try Data(contentsOf: unsupportedStore.fileURL)
require(unchangedFutureData == futureData, "拒绝加载时覆盖了未来版本数据")
let blockedMigrationStore = MetadataStore(directoryURL: directory.appendingPathComponent("blocked-migration"))
try FileManager.default.createDirectory(at: blockedMigrationStore.directoryURL.appendingPathComponent("metadata.v1.backup.json"), withIntermediateDirectories: true)
try legacyData.write(to: blockedMigrationStore.fileURL)
requireThrows("无法备份时不应继续迁移") { _ = try blockedMigrationStore.load() }
let unmodifiedLegacyData = try Data(contentsOf: blockedMigrationStore.fileURL)
require(unmodifiedLegacyData == legacyData, "迁移失败覆盖了原数据")

let sensitiveCurl = "curl 'https://example.test?private_param=fixture-query-secret' -H 'X-Custom-Auth: fixture-header-secret' -d '{\"api_key\":\"fixture-body-secret\"}'"
let redactedCurl = SafeCurl.redacted(sensitiveCurl)
require(!redactedCurl.contains("fixture-query-secret") && !redactedCurl.contains("fixture-header-secret") && !redactedCurl.contains("fixture-body-secret"), "请求脱敏未覆盖自定义 Header、Query 或 Body")
require(!SafeCurl.isReadOnly("curl -X POST https://example.test") && SafeCurl.isReadOnly("curl -H 'X-Custom-Auth: {{key}}' https://example.test"), "自动检查只读判定不正确")
requireThrows("Header 不应读取本地文件") { _ = try SafeCurl.parse("curl -H @private.txt https://example.test") }
requireThrows("Header 中的 Key 换行未被拒绝") {
    _ = try CurlValidator().execute(template: "curl -H 'X-API-Key: {{key}}' http://127.0.0.1:1", secrets: ["__default": "fixture\r\nX-Injected: true"], rule: ValidationRule(), returnBody: false)
}

if let cliPath = ProcessInfo.processInfo.environment["WHEREKEY_TEST_CLI"] {
    server.stop()
    let applicationServer = IPCServer { request in
        do {
            switch request.action {
            case "catalog": return IPCResponse(ok: true, catalog: custom.catalog())
            case "describe": return IPCResponse(ok: true, description: try custom.describe(service: request.service!))
            case "prepareRun": return IPCResponse(ok: true, preparedRun: try custom.prepareRun(service: request.service!, keyAlias: request.keyAlias, cwd: request.cwd!))
            case "check": return IPCResponse(ok: true, checkResult: try custom.check(service: request.service!, keyAlias: request.keyAlias))
            case "call": return IPCResponse(ok: true, checkResult: try custom.call(service: request.service!, keyAlias: request.keyAlias, cwd: request.cwd!))
            default: return IPCResponse(ok: false, error: "Unknown fixture action")
            }
        } catch { return IPCResponse(ok: false, error: error.localizedDescription) }
    }
    try applicationServer.start()
    defer { applicationServer.stop() }
    func cli(_ arguments: [String]) throws -> (Int32, String, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, stdout, stderr)
    }
    let cliCatalog = try cli(["catalog", "--json"])
    require(cliCatalog.0 == 0 && cliCatalog.1.contains("知识查询") && !cliCatalog.1.contains(customSecret), "CLI catalog 输出不兼容或泄露 Key")
    let cliDescription = try cli(["describe", "--service", "Tucui", "--json"])
    require(cliDescription.0 == 0 && cliDescription.1.contains("documentationURL"), "CLI describe 未保留字段与新元数据")
    let cliRun = try cli(["run", "--service", "Tucui", "--", "python3", "-c", "import os; assert os.environ['TUCUI_API_KEY'] == 'fixture-tucui-primary-secret'; print(os.environ['TUCUI_API_KEY']); print('run-ok')"])
    require(cliRun.0 == 0 && cliRun.1.contains("run-ok") && cliRun.1.contains("[REDACTED]") && !cliRun.1.contains(customSecret), "CLI run 注入或输出脱敏回归")
    let aliasRun = try cli(["run", "--service", "Tucui", "--key", "test", "--", "python3", "-c", "import os; assert os.environ['TUCUI_API_KEY'] == 'fixture-tucui-test-secret'; print('alias-ok')"])
    require(aliasRun.0 == 0 && aliasRun.1.contains("alias-ok"), "CLI --key 别名不兼容")
    let cliCheck = try cli(["check", "--service", "Tucui", "--json"])
    require(cliCheck.0 == 0 && cliCheck.1.contains("unchecked"), "无检查地址的 CLI check 被误报失效")
    if ProcessInfo.processInfo.environment["WHEREKEY_TEST_URL"] != nil {
        let cliCall = try cli(["call", "--service", "Business POST", "--json"])
        require(cliCall.0 == 0 && cliCall.1.contains("201"), "CLI call 业务请求不兼容")
        try custom.save(ServiceDraft(name: "Limited", credentials: [CredentialDraft(environmentVariable: "LIMITED_KEY", secret: "fixture-limited-secret")],
                                     validationCurl: "curl '\(legacyURL)status/429'"))
        let cliLimited = try cli(["check", "--service", "Limited", "--json"])
        require(cliLimited.0 == 1 && cliLimited.1.contains("rateLimited"), "CLI 限流未返回失败退出码")
    }
}

// Documentation imports never treat examples as real credentials or API origins.
let tucuiGuide = """
开发者 · 图萃
npm install --global tucui-cli
服务地址和 API Key 由邮件提供。
curl "$TUCUI_BASE_URL/api/query-linked" -H "X-API-Key: $TUCUI_API_KEY" -d '{"query":"研究问题"}'
"""
let docsCandidate = DocumentationImportParser.parse(tucuiGuide)[0]
require(docsCandidate.draft.name == "图萃 Tucui" && docsCandidate.draft.kind == .apiKey, "接入说明没有识别为图萃 API 服务")
require(docsCandidate.draft.credentials[0].secret.isEmpty && docsCandidate.draft.baseURL.isEmpty, "文档占位符或官网被保存为真实凭证/服务地址")
require(docsCandidate.draft.authentication == Authentication(kind: .header, fieldName: "X-API-Key"), "图萃鉴权方式未自动识别")
require(docsCandidate.draft.baseURLVariable == "TUCUI_BASE_URL" && docsCandidate.draft.checkPath == "/api/resources/available", "图萃变量或只读验证接口未配置")
require(!docsCandidate.draft.curlTemplate.contains("query-linked"), "文档示例被保存成可重放的业务请求")
let docsDirectory = directory.appendingPathComponent("documentation")
let docsSecrets = MemorySecrets()
let docsRepository = try WhereKeyRepository(metadataStore: MetadataStore(directoryURL: docsDirectory), keychain: docsSecrets)
let docsID = try docsRepository.save(docsCandidate.draft)
require(docsRepository.snapshot().credentials.isEmpty && docsSecrets.values.isEmpty, "待补充服务创建了虚假 Key 或 Keychain 项")
require(docsRepository.snapshot().services[0].setupMessage == "待补 Key 和地址", "未显示准确的待补充状态")
requireThrows("未补充的服务不应注入运行") { _ = try docsRepository.prepareRun(service: "图萃 Tucui", keyAlias: nil, cwd: directory.path) }
let docsUnchecked = try docsRepository.check(service: "图萃 Tucui", keyAlias: nil, automatic: true)
require(docsUnchecked.status == .unchecked && docsRepository.snapshot().usages.isEmpty, "未完成接入执行了请求或记录了使用")
let docsReloaded = try WhereKeyRepository(metadataStore: MetadataStore(directoryURL: docsDirectory), keychain: docsSecrets)
require(docsReloaded.snapshot().services[0].requiresBaseURL && docsReloaded.snapshot().services[0].setupMessage != nil, "待补充状态重启后丢失")
var supplement = try docsRepository.draft(for: docsID)
require(supplement.allowsIncomplete && supplement.credentials.count == 1, "补充界面缺少自动生成的 Key 字段")
supplement.credentials[0].secret = "fixture-tucui-auth-key"
try docsRepository.save(supplement)
require(docsRepository.snapshot().services[0].setupMessage == "待补地址", "只补 Key 后的状态错误")
let retainedKeyID = docsRepository.snapshot().credentials[0].id
supplement = try docsRepository.draft(for: docsID)
require(supplement.credentials[0].secret.isEmpty, "补充界面读出了原 Key 明文")

for placeholder in ["YOUR_API_KEY", "$TUCUI_API_KEY", "<api-key>", "{{key}}", "••••••", "sk-xxx"] {
    require(DocumentationImportParser.isPlaceholder(placeholder), "文档占位符被当成真实 Key")
}
let actualNote = tucuiGuide + "\nTUCUI_API_KEY=fixture-document-key\nTUCUI_BASE_URL=https://api.fixture.test"
let withKey = DocumentationImportParser.parse(actualNote)[0]
require(withKey.draft.credentials[0].secret == "fixture-document-key" && withKey.draft.baseURL == "https://api.fixture.test", "接入说明中的真实赋值未被保留")
let literalCurl = DocumentationImportParser.parse("curl https://example.test -H 'Authorization: Bearer fixture-real-curl-key'")
require(literalCurl.count == 1 && literalCurl[0].draft.kind == .curl, "已有真实 curl 的导入方式发生回归")
let genericGuide = DocumentationImportParser.parse("curl \"https://api.fixture.test/v1\" -H \"X-Client-Token: $ACME_API_KEY\"")[0]
require(genericGuide.draft.authentication == Authentication(kind: .header, fieldName: "X-Client-Token") && genericGuide.draft.credentials[0].secret.isEmpty, "通用 Header 文档未被识别")
let openAPI = DocumentationImportParser.parse(#"{"openapi":"3.0.0","info":{"title":"Acme"},"servers":[{"url":"https://api.fixture.test"}],"components":{"securitySchemes":{"key":{"type":"apiKey","in":"header","name":"X-Acme-Key"}}}}"#)[0]
require(openAPI.draft.name == "Acme" && openAPI.draft.baseURL == "https://api.fixture.test" && openAPI.draft.authentication.fieldName == "X-Acme-Key", "OpenAPI 接入说明未自动填写")
require(ServiceImportResolver.websiteURL("www.evidoc.cn")?.absoluteString == "https://www.evidoc.cn", "无协议网址不被识别")
require(ServiceImportResolver.websiteURL("TUCUI_API_KEY=fixture-test-key") == nil, "含 Key 的笔记被当成网址联网")
let strippedHTML = ServiceImportResolver.pageText("<script>fixture-script-secret</script><pre>&quot;X-API-Key: $TUCUI_API_KEY&quot;</pre>")
require(!strippedHTML.contains("fixture-script-secret") && strippedHTML.contains("\"X-API-Key"), "HTML 脚本未移除或代码实体未解码")

final class ImportResultBox: @unchecked Sendable { var value: Result<[NoteImportCandidate], Error>? }
func resolveDocumentation(_ input: String) throws -> [NoteImportCandidate] {
    let signal = DispatchSemaphore(value: 0)
    let box = ImportResultBox()
    Task.detached {
        do { box.value = .success(try await ServiceImportResolver().resolve(input)) }
        catch { box.value = .failure(error) }
        signal.signal()
    }
    guard signal.wait(timeout: .now() + 45) == .success else { throw WhereKeyError.unavailable("Documentation fixture timed out") }
    return try box.value!.get()
}
if let testURL = ProcessInfo.processInfo.environment["WHEREKEY_TEST_URL"] {
    let fromURL = try resolveDocumentation(testURL + "doc-site/")
    require(fromURL.count == 1 && fromURL[0].draft.name == "图萃 Tucui", "粘贴官网没有自动找到开发者页面")
    require(fromURL[0].draft.credentials[0].secret.isEmpty, "网页脚本或示例被导入成 Key")
    requireThrows("含 Key 的网址不应被发送出去") { _ = try resolveDocumentation(testURL + "doc-site/?api_key=fixture-secret") }
    supplement.baseURL = String(testURL.dropLast())
    try docsRepository.save(supplement)
    require(docsRepository.snapshot().services[0].setupMessage == nil && docsRepository.snapshot().credentials[0].id == retainedKeyID, "补充地址后没有激活服务或更换了 Key 引用")
    let docsChecked = try docsRepository.check(service: "图萃 Tucui", keyAlias: nil, automatic: true)
    require(docsChecked.status == .valid && docsChecked.httpStatus == 200, "自动配置的 Header 鉴权或资源验证接口不通")
    let docsRun = try docsRepository.prepareRun(service: "图萃 Tucui", keyAlias: nil, cwd: directory.path)
    require(docsRun.environment["TUCUI_API_KEY"] == "fixture-tucui-auth-key" && docsRun.environment["TUCUI_BASE_URL"] == String(testURL.dropLast()), "文档导入→补充→注入的完整流程不通")
}
if let liveURL = ProcessInfo.processInfo.environment["WHEREKEY_LIVE_DOC_URL"] {
    let live = try resolveDocumentation(liveURL)
    require(live.count == 1 && live[0].draft.name == "图萃 Tucui" && live[0].draft.credentials[0].secret.isEmpty && live[0].draft.baseURL.isEmpty, "图萃真实官网导入不符合接入说明")
    print("Live documentation import passed: 图萃 Tucui (pending Key and service address)")
}

// Metadata discovery must not ask for any Keychain permissions, even with curls.
let accessDirectory = directory.appendingPathComponent("access-policy")
let accessSecrets = MemorySecrets()
let accessRepository = try WhereKeyRepository(metadataStore: MetadataStore(directoryURL: accessDirectory), keychain: accessSecrets)
let targetID = try accessRepository.save(ServiceDraft(name: "Selected service", checkMode: .automatic,
    checkURL: (ProcessInfo.processInfo.environment["WHEREKEY_TEST_URL"] ?? "http://127.0.0.1:1/") + "header",
    authentication: Authentication(kind: .header, fieldName: "X-Tucui-Key"),
    credentials: [CredentialDraft(alias: "production", environmentVariable: "SELECTED_KEY", secret: "fixture-header-secret"),
                  CredentialDraft(alias: "spare", environmentVariable: "SELECTED_KEY", secret: "fixture-spare-secret", isDefault: false)]))
try accessRepository.save(ServiceDraft(kind: .curl, name: "Unrelated curl", credentials: [], curlTemplate: "curl https://example.test -H 'X-Private: fixture-private-secret'"))
accessSecrets.readAccounts = []
let safeCatalog = accessRepository.catalog()
let safeDescription = try accessRepository.describe(service: "Selected service")
require(accessSecrets.readAccounts.isEmpty, "catalog / describe 读取了 Keychain 或其他服务")
require(safeDescription.service.name == "Selected service" && safeCatalog.count == 2, "纯元数据目录内容错误")
let catalogWithoutSecrets = String(decoding: try JSONEncoder().encode(safeCatalog), as: UTF8.self)
require(!catalogWithoutSecrets.contains("fixture-private-secret"), "目录泄露了未提取的 curl 凭证")
let selectedRecord = accessRepository.snapshot().services.first { $0.id == targetID }!
let selectedAccount = KeychainStore.credentialAccount(selectedRecord.defaultCredentialID!)
accessSecrets.lockedAccounts.insert(selectedAccount)
let blockedCheck = try accessRepository.check(service: "Selected service", keyAlias: nil, automatic: true)
require(blockedCheck.status == .authorizationRequired && blockedCheck.status.isFailure, "后台授权失败未显示待授权")
require(accessSecrets.readAccounts == [selectedAccount] && accessSecrets.interactiveReadAccounts.isEmpty, "自动检查读取了备用 Key、交互授权或重复重试")
require(accessRepository.snapshot().credentials.first { $0.id == selectedRecord.defaultCredentialID }?.lastCheckedAt == nil, "未授权的检查被记录为网络检查")
accessSecrets.readAccounts = []
try accessRepository.authorize(service: "Selected service")
require(accessSecrets.interactiveReadAccounts == [selectedAccount] && accessSecrets.readAccounts == [selectedAccount], "单次授权访问了多项或其他服务")
accessSecrets.readAccounts = []
let singlePrepared = try accessRepository.prepareRun(service: "Selected service", keyAlias: nil, cwd: directory.path)
require(singlePrepared.credentialAlias == "production" && accessSecrets.readAccounts == [selectedAccount], "run 读取了未选择的 Key")
if ProcessInfo.processInfo.environment["WHEREKEY_TEST_URL"] != nil {
    accessSecrets.readAccounts = []
    let automaticResults = accessRepository.checkAllAPIKeys()
    require(automaticResults.count == 1 && automaticResults[0].1 == "production", "启动检查遍历了备用 Key")
    require(accessSecrets.readAccounts == [selectedAccount], "启动检查读取了不必要的 Key")
}
var deniedReads = 0
var interactionBefore = DarwinBoolean(false)
require(SecKeychainGetUserInteractionAllowed(&interactionBefore) == errSecSuccess, "无法取得测试前的交互策略")
let quietStore = KeychainStore(readOperation: { query in
    deniedReads += 1
    require((query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true, "静默读取允许了认证 UI")
    var legacyUI = DarwinBoolean(true)
    require(SecKeychainGetUserInteractionAllowed(&legacyUI) == errSecSuccess && !legacyUI.boolValue, "旧登录钥匙串的认证 UI 未被禁用")
    return (errSecAuthFailed, nil)
})
requireThrows("授权失败应返回明确错误") { _ = try quietStore.read(account: "synthetic-account") }
require(deniedReads == 1, "鉴权失败自动重试，可能产生多次弹窗")
var interactionAfterFailure = DarwinBoolean(false)
require(SecKeychainGetUserInteractionAllowed(&interactionAfterFailure) == errSecSuccess && interactionAfterFailure.boolValue == interactionBefore.boolValue, "失败后没有恢复原交互策略")
var explicitReads = 0
let deliberateStore = KeychainStore(readOperation: { query in
    explicitReads += 1
    require((query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == false, "明确授权未允许单次认证")
    return (errSecSuccess, Data("fixture-authorized-value".utf8))
})
_ = try deliberateStore.read(account: "synthetic-account", interactive: true)
require(explicitReads == 1, "明确授权被执行多次")
var interactionAfterAuthorization = DarwinBoolean(false)
require(SecKeychainGetUserInteractionAllowed(&interactionAfterAuthorization) == errSecSuccess && interactionAfterAuthorization.boolValue == interactionBefore.boolValue, "明确授权后没有恢复原交互策略")

print("WhereKey self-test passed (\(assertionCount) assertions)")
