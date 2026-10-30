import Foundation

public struct NoteImportCandidate: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var draft: ServiceDraft
    public var sourcePreview: String
    public var automaticAdditions: [String]

    public init(
        id: UUID = UUID(),
        draft: ServiceDraft,
        sourcePreview: String,
        automaticAdditions: [String] = []
    ) {
        self.id = id
        self.draft = draft
        self.sourcePreview = sourcePreview
        self.automaticAdditions = automaticAdditions
    }
}

/// Turns informal notes into ordinary service drafts. Parsing never writes to
/// disk or Keychain; callers still have to explicitly confirm and save a draft.
public enum NoteImportParser {
    public static func parse(_ input: String) -> [NoteImportCandidate] {
        let normalized = input
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00a0}", with: " ")
        let candidates = blocks(from: normalized).compactMap(parseBlock)
        return mergeCompatibleCandidates(candidates)
    }

    private struct ProviderPreset {
        let name: String
        let keywords: [String]
        let domains: [String]
        let environmentVariable: String
        let baseURL: String
        let baseURLVariable: String
        let keyPrefixes: [String]
    }

    private struct SecretMatch: Equatable {
        let value: String
        let environmentVariable: String?
    }

    // Specific providers precede broader OpenAI-compatible matches.
    private static let presets: [ProviderPreset] = [
        ProviderPreset(
            name: "Azure OpenAI",
            keywords: ["azure openai", "azure_openai"],
            domains: ["openai.azure.com"],
            environmentVariable: "AZURE_OPENAI_API_KEY",
            baseURL: "",
            baseURLVariable: "AZURE_OPENAI_ENDPOINT",
            keyPrefixes: []
        ),
        ProviderPreset(
            name: "DeepSeek",
            keywords: ["deepseek", "深度求索"],
            domains: ["api.deepseek.com", "platform.deepseek.com", "deepseek.com"],
            environmentVariable: "DEEPSEEK_API_KEY",
            baseURL: "https://api.deepseek.com",
            baseURLVariable: "DEEPSEEK_BASE_URL",
            keyPrefixes: []
        ),
        ProviderPreset(
            name: "OpenRouter",
            keywords: ["openrouter"],
            domains: ["openrouter.ai"],
            environmentVariable: "OPENROUTER_API_KEY",
            baseURL: "https://openrouter.ai/api/v1",
            baseURLVariable: "OPENROUTER_BASE_URL",
            keyPrefixes: ["sk-or-v1-"]
        ),
        ProviderPreset(
            name: "Anthropic",
            keywords: ["anthropic", "claude"],
            domains: ["api.anthropic.com", "console.anthropic.com"],
            environmentVariable: "ANTHROPIC_API_KEY",
            baseURL: "https://api.anthropic.com",
            baseURLVariable: "ANTHROPIC_BASE_URL",
            keyPrefixes: ["sk-ant-"]
        ),
        ProviderPreset(
            name: "Gemini",
            keywords: ["gemini", "google ai", "googleai", "谷歌模型"],
            domains: ["generativelanguage.googleapis.com", "aistudio.google.com"],
            environmentVariable: "GEMINI_API_KEY",
            baseURL: "https://generativelanguage.googleapis.com",
            baseURLVariable: "GEMINI_BASE_URL",
            keyPrefixes: ["aiza"]
        ),
        ProviderPreset(
            name: "Moonshot",
            keywords: ["moonshot", "kimi", "月之暗面"],
            domains: ["api.moonshot.cn", "platform.moonshot.cn"],
            environmentVariable: "MOONSHOT_API_KEY",
            baseURL: "https://api.moonshot.cn/v1",
            baseURLVariable: "MOONSHOT_BASE_URL",
            keyPrefixes: []
        ),
        ProviderPreset(
            name: "智谱 AI",
            keywords: ["zhipu", "chatglm", "glm", "智谱"],
            domains: ["open.bigmodel.cn", "bigmodel.cn"],
            environmentVariable: "ZHIPUAI_API_KEY",
            baseURL: "https://open.bigmodel.cn/api/paas/v4",
            baseURLVariable: "ZHIPUAI_BASE_URL",
            keyPrefixes: []
        ),
        ProviderPreset(
            name: "DashScope",
            keywords: ["dashscope", "qwen", "通义千问", "阿里云百炼", "百炼"],
            domains: ["dashscope.aliyuncs.com", "bailian.console.aliyun.com"],
            environmentVariable: "DASHSCOPE_API_KEY",
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            baseURLVariable: "DASHSCOPE_BASE_URL",
            keyPrefixes: []
        ),
        ProviderPreset(
            name: "SiliconFlow",
            keywords: ["siliconflow", "silicon flow", "硅基流动"],
            domains: ["api.siliconflow.cn", "cloud.siliconflow.cn"],
            environmentVariable: "SILICONFLOW_API_KEY",
            baseURL: "https://api.siliconflow.cn/v1",
            baseURLVariable: "SILICONFLOW_BASE_URL",
            keyPrefixes: []
        ),
        ProviderPreset(
            name: "火山方舟",
            keywords: ["volcengine", "doubao", "火山方舟", "豆包"],
            domains: ["volces.com", "volcengine.com"],
            environmentVariable: "ARK_API_KEY",
            baseURL: "https://ark.cn-beijing.volces.com/api/v3",
            baseURLVariable: "ARK_BASE_URL",
            keyPrefixes: []
        ),
        ProviderPreset(
            name: "Groq",
            keywords: ["groq"],
            domains: ["api.groq.com", "console.groq.com"],
            environmentVariable: "GROQ_API_KEY",
            baseURL: "https://api.groq.com/openai/v1",
            baseURLVariable: "GROQ_BASE_URL",
            keyPrefixes: ["gsk_"]
        ),
        ProviderPreset(
            name: "xAI",
            keywords: ["xai", "grok"],
            domains: ["api.x.ai", "console.x.ai"],
            environmentVariable: "XAI_API_KEY",
            baseURL: "https://api.x.ai/v1",
            baseURLVariable: "XAI_BASE_URL",
            keyPrefixes: ["xai-"]
        ),
        ProviderPreset(
            name: "Mistral",
            keywords: ["mistral"],
            domains: ["api.mistral.ai", "console.mistral.ai"],
            environmentVariable: "MISTRAL_API_KEY",
            baseURL: "https://api.mistral.ai/v1",
            baseURLVariable: "MISTRAL_BASE_URL",
            keyPrefixes: []
        ),
        ProviderPreset(
            name: "Cohere",
            keywords: ["cohere"],
            domains: ["api.cohere.com", "dashboard.cohere.com"],
            environmentVariable: "COHERE_API_KEY",
            baseURL: "https://api.cohere.com/v2",
            baseURLVariable: "COHERE_BASE_URL",
            keyPrefixes: []
        ),
        ProviderPreset(
            name: "Hugging Face",
            keywords: ["huggingface", "hugging face"],
            domains: ["huggingface.co"],
            environmentVariable: "HF_TOKEN",
            baseURL: "",
            baseURLVariable: "",
            keyPrefixes: ["hf_"]
        ),
        ProviderPreset(
            name: "OpenAI",
            keywords: ["openai", "chatgpt"],
            domains: ["api.openai.com", "platform.openai.com"],
            environmentVariable: "OPENAI_API_KEY",
            baseURL: "https://api.openai.com/v1",
            baseURLVariable: "OPENAI_BASE_URL",
            keyPrefixes: ["sk-proj-", "sk-svcacct-"]
        ),
    ]

    private static func blocks(from text: String) -> [[String]] {
        var result: [[String]] = []
        var current: [String] = []

        func flush() {
            if !current.isEmpty { result.append(current) }
            current.removeAll(keepingCapacity: true)
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
                continue
            }

            let currentText = current.joined(separator: "\n")
            let currentHasSignal = hasImportSignal(currentText)
            let currentHasCurl = containsCurl(currentText)
            let incomingPreset = bestPreset(for: line, secrets: extractSecrets(line))
            let currentPreset = bestPreset(for: currentText, secrets: extractSecrets(currentText))
            let startsAnotherCurl = startsWithCurl(line) && currentHasCurl
            let startsNewProvider = currentHasSignal && !currentHasCurl && incomingPreset != nil && incomingPreset?.name != currentPreset?.name
            let startsGenericHeading = currentHasSignal && !currentHasCurl && incomingPreset == nil && looksLikeHeading(line)

            if startsAnotherCurl || startsNewProvider || startsGenericHeading { flush() }
            current.append(rawLine)
        }
        flush()
        return result
    }

    private static func parseBlock(_ lines: [String]) -> NoteImportCandidate? {
        let source = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return nil }
        if let curlIndex = lines.firstIndex(where: { startsWithCurl($0.trimmingCharacters(in: .whitespaces)) }) {
            return parseCurlBlock(lines, curlIndex: curlIndex, source: source)
        }
        return parseAPIBlock(lines, source: source)
    }

    private static func parseCurlBlock(_ lines: [String], curlIndex: Int, source: String) -> NoteImportCandidate? {
        let command = lines[curlIndex...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let preset = bestPreset(for: source, secrets: extractSecrets(source))
        let extracted = SafeCurl.extractFirstSecret(from: command, alias: "default")
        let template = extracted?.template ?? command
        guard (try? SafeCurl.parse(template.replacingOccurrences(of: "{{secret:default}}", with: "placeholder"))) != nil else {
            return nil
        }

        let urls = extractURLs(command)
        let headingLines = Array(lines.prefix(curlIndex))
        let name = preferredName(from: headingLines, preset: preset, fallbackURL: urls.first, ordinal: nil)
        let environment = preset?.environmentVariable ?? "API_KEY"
        let credentials = extracted.map {
            [CredentialDraft(alias: "default", environmentVariable: environment, secret: $0.secret, isDefault: true)]
        } ?? []
        var additions: [String] = []
        if let preset { additions.append("已识别为 \(preset.name)") }
        if extracted != nil { additions.append("已从 Header 提取 Key") }
        if headingLines.isEmpty { additions.append("已根据请求生成服务名") }

        let draft = ServiceDraft(
            kind: .curl,
            name: name,
            environmentVariable: environment,
            baseURL: "",
            baseURLVariable: "",
            credentials: credentials,
            curlTemplate: template
        )
        let secrets = extracted.map { [$0.secret] } ?? []
        return NoteImportCandidate(
            draft: draft,
            sourcePreview: redactedPreview(source, secrets: secrets),
            automaticAdditions: additions
        )
    }

    private static func parseAPIBlock(_ lines: [String], source: String) -> NoteImportCandidate? {
        let secrets = extractSecrets(source)
        let urls = extractURLs(source)
        let preset = bestPreset(for: source, secrets: secrets)

        if secrets.isEmpty {
            guard let url = urls.first, looksLikeCallableURL(url) else { return nil }
            let name = preferredName(from: lines, preset: preset, fallbackURL: url, ordinal: nil)
            let draft = ServiceDraft(
                kind: .curl,
                name: name,
                environmentVariable: "",
                baseURL: "",
                baseURLVariable: "",
                credentials: [],
                curlTemplate: "curl '\(url)'"
            )
            return NoteImportCandidate(
                draft: draft,
                sourcePreview: redactedPreview(source, secrets: []),
                automaticAdditions: ["仅检测到 URL，已按 GET curl 服务准备"]
            )
        }

        let explicitEnvironment = secrets.compactMap(\.environmentVariable).first
        let environment = explicitEnvironment ?? preset?.environmentVariable ?? "API_KEY"
        let suppliedURL = urls.first
        let shouldUsePresetURL = suppliedURL == nil || isHomepageURL(suppliedURL!, for: preset)
        let baseURL = shouldUsePresetURL ? (preset?.baseURL ?? suppliedURL ?? "") : (suppliedURL ?? "")
        let baseURLVariable = preset?.baseURLVariable.isEmpty == false
            ? preset!.baseURLVariable
            : suggestedBaseURLVariable(from: environment)
        let name = preferredName(from: lines, preset: preset, fallbackURL: suppliedURL, ordinal: nil)

        var credentialDrafts: [CredentialDraft] = []
        for (index, match) in secrets.enumerated() {
            credentialDrafts.append(CredentialDraft(
                alias: index == 0 ? "default" : "key-\(index + 1)",
                environmentVariable: match.environmentVariable ?? environment,
                secret: match.value,
                isDefault: index == 0
            ))
        }

        var additions: [String] = []
        if let preset { additions.append("已识别为 \(preset.name)") }
        if suppliedURL == nil, !baseURL.isEmpty { additions.append("已补全 API 地址：\(baseURL)") }
        if suppliedURL != nil, shouldUsePresetURL, suppliedURL != baseURL, !baseURL.isEmpty {
            additions.append("已将官网地址转为 API 地址：\(baseURL)")
        }
        if explicitEnvironment == nil { additions.append("已补全环境变量：\(environment)") }

        let draft = ServiceDraft(
            kind: .apiKey,
            name: name,
            environmentVariable: environment,
            baseURL: baseURL,
            baseURLVariable: baseURL.isEmpty ? "" : baseURLVariable,
            credentials: credentialDrafts,
            curlTemplate: "",
            validationCurl: ""
        )
        return NoteImportCandidate(
            draft: draft,
            sourcePreview: redactedPreview(source, secrets: secrets.map(\.value)),
            automaticAdditions: additions
        )
    }

    private static func mergeCompatibleCandidates(_ input: [NoteImportCandidate]) -> [NoteImportCandidate] {
        var result: [NoteImportCandidate] = []
        for candidate in input {
            guard candidate.draft.kind == .apiKey,
                  let index = result.firstIndex(where: {
                      $0.draft.kind == .apiKey &&
                      $0.draft.name.caseInsensitiveCompare(candidate.draft.name) == .orderedSame &&
                      $0.draft.baseURL == candidate.draft.baseURL
                  }) else {
                result.append(candidate)
                continue
            }
            var merged = result[index]
            let existingSecrets = Set(merged.draft.credentials.map(\.secret))
            for credential in candidate.draft.credentials where !existingSecrets.contains(credential.secret) {
                var appended = credential
                appended.alias = "key-\(merged.draft.credentials.count + 1)"
                appended.isDefault = false
                merged.draft.credentials.append(appended)
            }
            merged.sourcePreview += "\n\n" + candidate.sourcePreview
            merged.automaticAdditions = Array(Set(merged.automaticAdditions + candidate.automaticAdditions)).sorted()
            result[index] = merged
        }
        return result
    }

    private static func extractSecrets(_ text: String) -> [SecretMatch] {
        var results: [SecretMatch] = []

        addMatches(
            pattern: #"(?i)\b([a-z_][a-z0-9_]*(?:api_key|access_key|key|token|secret))\s*[:=：]\s*[\"'“”]?([a-z0-9][a-z0-9._+\-/=]{7,})"#,
            in: text,
            valueGroup: 2,
            environmentGroup: 1,
            to: &results
        )
        addMatches(
            pattern: #"(?i)(?:api\s*key|apikey|access\s*key|token|secret|密钥|令牌|key)\s*(?:[:=：]|是|为)?\s*[\"'“”]?([a-z0-9][a-z0-9._+\-/=]{7,})"#,
            in: text,
            valueGroup: 1,
            environmentGroup: nil,
            to: &results
        )
        addMatches(
            pattern: #"(?i)(?<![a-z0-9])((?:sk-(?:ant-|or-v1-)?|gsk_|hf_|xai-|aiza)[a-z0-9_-]{10,})(?![a-z0-9])"#,
            in: text,
            valueGroup: 1,
            environmentGroup: nil,
            to: &results
        )
        addMatches(
            pattern: #"(?im)^\s*[\"'“”]?([a-z0-9][a-z0-9._+\-/=]{15,})[\"'“”]?\s*$"#,
            in: text,
            valueGroup: 1,
            environmentGroup: nil,
            to: &results
        )

        var seen = Set<String>()
        return results.filter { match in
            let lowered = match.value.lowercased()
            let hasOpaqueMarker = match.value.contains(where: { $0.isNumber }) || match.value.contains(where: { "_-./+=".contains($0) })
            guard hasOpaqueMarker,
                  !lowered.hasPrefix("http"),
                  !lowered.contains("redacted"),
                  !lowered.contains("your_"),
                  !lowered.contains("example") else { return false }
            return seen.insert(match.value).inserted
        }
    }

    private static func addMatches(
        pattern: String,
        in text: String,
        valueGroup: Int,
        environmentGroup: Int?,
        to results: inout [SecretMatch]
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            guard let valueRange = Range(match.range(at: valueGroup), in: text) else { continue }
            let value = String(text[valueRange]).trimmingCharacters(in: CharacterSet(charactersIn: "'\"“”,;，；。"))
            let environment: String?
            if let environmentGroup,
               let environmentRange = Range(match.range(at: environmentGroup), in: text) {
                environment = String(text[environmentRange]).uppercased()
            } else {
                environment = nil
            }
            results.append(SecretMatch(value: value, environmentVariable: environment))
        }
    }

    private static func extractURLs(_ text: String) -> [String] {
        var seen = Set<String>()
        var values: [String] = []
        let patterns: [(String, String)] = [
            (#"https?://[^\s<>\"'“”）)\]}，,；;]+"#, ""),
            (#"(?i)(?<![a-z0-9./])(?:localhost|(?:\d{1,3}\.){3}\d{1,3}):\d{2,5}(?:/[^\s<>\"'“”）)\]}，,；;]*)?"#, "http://"),
        ]
        let range = NSRange(text.startIndex..., in: text)
        for (pattern, prefix) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            for match in regex.matches(in: text, range: range) {
                guard let swiftRange = Range(match.range, in: text) else { continue }
                var value = String(text[swiftRange]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;，；。"))
                if !prefix.isEmpty && !value.lowercased().hasPrefix("http") { value = prefix + value }
                if seen.insert(value).inserted { values.append(value) }
            }
        }
        return values
    }

    private static func bestPreset(for text: String, secrets: [SecretMatch]) -> ProviderPreset? {
        let lowered = text.lowercased()
        var best: (preset: ProviderPreset, score: Int)?
        for preset in presets {
            var score = 0
            if preset.domains.contains(where: { lowered.contains($0) }) { score += 100 }
            if preset.keywords.contains(where: { lowered.contains($0) }) { score += 40 }
            if secrets.contains(where: { secret in preset.keyPrefixes.contains(where: { secret.value.lowercased().hasPrefix($0) }) }) { score += 80 }
            if secrets.contains(where: { $0.environmentVariable == preset.environmentVariable }) { score += 90 }
            if score > (best?.score ?? 0) { best = (preset, score) }
        }
        return best?.preset
    }

    private static func preferredName(
        from lines: [String],
        preset: ProviderPreset?,
        fallbackURL: String?,
        ordinal: Int?
    ) -> String {
        for rawLine in lines {
            let candidate = cleanedHeading(rawLine)
            guard !candidate.isEmpty,
                  candidate.count <= 60,
                  extractURLs(candidate).isEmpty,
                  extractSecrets(candidate).isEmpty,
                  !startsWithCurl(candidate),
                  !isFieldLine(candidate) else { continue }
            if let preset, isGenericProviderHeading(candidate, preset: preset) { return preset.name }
            return candidate
        }
        if let preset { return preset.name }
        if let fallbackURL, let host = URL(string: fallbackURL)?.host, !host.isEmpty {
            return host + (ordinal.map { " \($0)" } ?? "")
        }
        return "导入服务" + (ordinal.map { " \($0)" } ?? "")
    }

    private static func cleanedHeading(_ line: String) -> String {
        line
            .replacingOccurrences(of: #"^\s*(?:#{1,6}|[-*>•]|\d+[.)、])\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isGenericProviderHeading(_ heading: String, preset: ProviderPreset) -> Bool {
        var value = heading.lowercased()
        for token in preset.keywords + [preset.name.lowercased(), "official", "官网", "api", "key", "服务", "模型"] {
            value = value.replacingOccurrences(of: token, with: "")
        }
        value = value.replacingOccurrences(of: #"[\s:：_\-/]+"#, with: "", options: .regularExpression)
        return value.isEmpty
    }

    private static func isFieldLine(_ line: String) -> Bool {
        let lowered = line.lowercased()
        return lowered.range(of: #"^\s*(?:api\s*key|apikey|key|token|secret|url|endpoint|base\s*url|密钥|令牌|地址|接口)\s*[:=：]"#, options: .regularExpression) != nil
    }

    private static func looksLikeHeading(_ line: String) -> Bool {
        let cleaned = cleanedHeading(line)
        guard (2...60).contains(cleaned.count),
              extractURLs(cleaned).isEmpty,
              extractSecrets(cleaned).isEmpty,
              !isFieldLine(cleaned),
              !startsWithCurl(cleaned) else { return false }
        return !cleaned.contains("{") && !cleaned.contains("}") && !cleaned.contains("=")
    }

    private static func startsWithCurl(_ line: String) -> Bool {
        let lowered = line.trimmingCharacters(in: .whitespaces).lowercased()
        return lowered.hasPrefix("curl ") || lowered == "curl" || lowered.hasPrefix("/usr/bin/curl ")
    }

    private static func containsCurl(_ text: String) -> Bool {
        text.components(separatedBy: "\n").contains { startsWithCurl($0) }
    }

    private static func hasImportSignal(_ text: String) -> Bool {
        containsCurl(text) || !extractSecrets(text).isEmpty || !extractURLs(text).isEmpty
    }

    private static func looksLikeCallableURL(_ value: String) -> Bool {
        guard let url = URL(string: value), let host = url.host else { return false }
        let loweredHost = host.lowercased()
        let documentationHosts = ["docs.", "documentation.", "platform.openai.com", "console.anthropic.com", "aistudio.google.com"]
        return !documentationHosts.contains(where: { loweredHost.hasPrefix($0) || loweredHost == $0 })
    }

    private static func isHomepageURL(_ value: String, for preset: ProviderPreset?) -> Bool {
        guard let preset, let url = URL(string: value), let host = url.host?.lowercased() else { return false }
        guard preset.domains.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) else { return false }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.isEmpty || host.hasPrefix("platform.") || host.hasPrefix("console.") || host.hasPrefix("aistudio.")
    }

    private static func suggestedBaseURLVariable(from environment: String) -> String {
        if environment.hasSuffix("_API_KEY") { return String(environment.dropLast(8)) + "_BASE_URL" }
        if environment.hasSuffix("_KEY") { return String(environment.dropLast(4)) + "_BASE_URL" }
        return "API_BASE_URL"
    }

    private static func redactedPreview(_ source: String, secrets: [String]) -> String {
        var value = SafeCurl.redacted(source)
        for secret in secrets where !secret.isEmpty {
            value = value.replacingOccurrences(of: secret, with: "[REDACTED]")
        }
        if value.count > 800 { value = String(value.prefix(800)) + "…" }
        return value
    }
}
