import Foundation
import WhereKeyCore

final class MemorySecrets: SecretStoring {
    var values: [String: String] = [:]
    func save(_ value: String, account: String) throws { values[account] = value }
    func read(account: String) throws -> String {
        guard let value = values[account] else { throw WhereKeyError.notFound("missing") }
        return value
    }
    func delete(account: String) throws { values.removeValue(forKey: account) }
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

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
print("WhereKey self-test passed")
