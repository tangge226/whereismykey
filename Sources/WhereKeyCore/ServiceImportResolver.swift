import Foundation

/// Reads public documentation without cookies, credentials, scripts or command execution.
/// Pasted notes containing credentials are always parsed locally.
public final class ServiceImportResolver: @unchecked Sendable {
    public init() {}

    public func resolve(_ input: String) async throws -> [NoteImportCandidate] {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = Self.websiteURL(text) {
            let page = try await load(url)
            let documentation = Self.documentationLink(in: page.html, relativeTo: page.url)
            if let documentation, documentation != page.url {
                let docs = try await load(documentation)
                return DocumentationImportParser.parse(docs.text, sourceURL: docs.url)
            }
            return DocumentationImportParser.parse(page.text, sourceURL: page.url)
        }
        return DocumentationImportParser.parse(text)
    }

    public static func websiteURL(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\.", with: ".")
        guard !text.contains(where: { $0.isWhitespace }) else { return nil }
        let qualified = text.hasPrefix("http://") || text.hasPrefix("https://")
        guard qualified || text.range(of: #"^(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}(?:[/:?#].*)?$"#, options: .regularExpression) != nil else { return nil }
        return URL(string: qualified ? text : "https://" + text)
    }

    private func load(_ url: URL) async throws -> (html: String, text: String, url: URL) {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(c.scheme?.lowercased() ?? ""), c.host != nil,
              c.user == nil, c.password == nil, c.fragment == nil,
              !(c.queryItems ?? []).contains(where: { $0.name.range(of: #"(?i)(key|token|secret|password|signature|credential)"#, options: .regularExpression) != nil }) else {
            throw WhereKeyError.invalidInput("请粘贴不含 Key、账号密码或签名的公开文档网址；含 Key 的内容可直接粘贴为文本")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration, delegate: DocumentationRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("WhereKey/1.3 Documentation Import", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html, application/json, text/plain", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw WhereKeyError.unavailable("页面暂时无法读取，请复制页面内容后粘贴")
        }
        let contentType = http.mimeType ?? "text/html"
        guard contentType.hasPrefix("text/") || contentType.contains("json") else {
            throw WhereKeyError.invalidInput("请粘贴开发者页面、接口文档网址或页面文字")
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 1_048_576 else { throw WhereKeyError.invalidInput("页面内容过大，请只复制接入说明部分") }
            data.append(byte)
        }
        let html = String(decoding: data, as: UTF8.self)
        return (html, contentType.contains("html") ? Self.pageText(html) : html, response.url ?? url)
    }

    public static func pageText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: #"(?is)<(script|style)\b[^>]*>.*?</\1\s*>|<!--.*?-->"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)<br\s*/?>|</(?:p|pre|div|section|h[1-6]|li|tr)>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (entity, value) in [("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        if let regex = try? NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|[0-9]+);"#) {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                guard let r = Range(match.range(at: 1), in: text), let whole = Range(match.range, in: text) else { continue }
                let number = String(text[r])
                let code = number.hasPrefix("x") ? UInt32(number.dropFirst(), radix: 16) : UInt32(number)
                if let code, let scalar = UnicodeScalar(code) { text.replaceSubrange(whole, with: String(scalar)) }
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func documentationLink(in html: String, relativeTo url: URL) -> URL? {
        if url.path.split(separator: "/").contains(where: { ["developers", "developer", "docs", "documentation", "openapi.json"].contains(String($0).lowercased()) }) { return nil }
        guard let regex = try? NSRegularExpression(pattern: #"(?i)href\s*=\s*["']([^"']*(?:developers?|docs?|documentation|openapi)[^"']*)["']"#) else { return nil }
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range(at: 1), in: html),
                  let candidate = URL(string: String(html[range]), relativeTo: url)?.absoluteURL,
                  candidate.host?.lowercased() == url.host?.lowercased(),
                  ["http", "https"].contains(candidate.scheme?.lowercased() ?? ""),
                  candidate != url else { continue }
            return candidate
        }
        return nil
    }
}

private final class DocumentationRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let old = task.originalRequest?.url, let new = request.url,
              old.host?.lowercased().replacingOccurrences(of: "www.", with: "") == new.host?.lowercased().replacingOccurrences(of: "www.", with: ""),
              new.user == nil, new.password == nil,
              old.scheme != "https" || new.scheme == "https", new.query == nil,
              task.countOfBytesReceived < 1_048_576 else { completionHandler(nil); return }
        completionHandler(request)
    }
}

public enum DocumentationImportParser {
    public static func parse(_ text: String, sourceURL: URL? = nil) -> [NoteImportCandidate] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        if normalized.contains("TUCUI_API_KEY") && (normalized.contains("tucui") || normalized.contains("X-API-Key")) {
            let env = "TUCUI_API_KEY"
            let secret = assignedValue(env, in: normalized).flatMap { isPlaceholder($0) ? nil : $0 } ?? ""
            let base = assignedValue("TUCUI_BASE_URL", in: normalized).flatMap { validAPIURL($0) } ?? ""
            let draft = ServiceDraft(name: "图萃 Tucui", category: .data, summary: "专病模型、知识检索与带引用的研究依据",
                tags: ["图萃", "Tucui", "医学", "知识库"], documentationURL: "https://www.evidoc.cn/developers/",
                checkMode: .automatic, authentication: Authentication(kind: .header, fieldName: "X-API-Key"),
                allowsIncomplete: true, requiresBaseURL: true, checkPath: "/api/resources/available",
                environmentVariable: env, baseURL: base, baseURLVariable: "TUCUI_BASE_URL",
                credentials: [CredentialDraft(environmentVariable: env, secret: secret)])
            return [NoteImportCandidate(draft: draft, sourcePreview: "已识别图萃官方接入说明；原文不保存。", automaticAdditions: [
                "已识别图萃 Tucui，自动配置 X-API-Key 鉴权", "已配置 Key 和服务地址的变量，无需手填变量名",
                "使用授权资源接口验证，不执行研究查询", "服务地址和 Key 由授权邮件提供；官网地址不会作为 API 地址"
            ])]
        }
        if let openAPI = openAPI(text, sourceURL: sourceURL) { return [openAPI] }
        let env = capture(#"\$\{?([A-Za-z_][A-Za-z0-9_]*(?:API_KEY|TOKEN|KEY))\}?"#, in: normalized)
        let header = capture(#"(?i)(?:-H|--header)\s*["']([^:"'\r\n]+):\s*(?:\$|<|\{\{)"#, in: normalized)
        let isGuide = env != nil || normalized.contains("YOUR_API_KEY") || (normalized.contains("curl") && normalized.contains("{{key}}"))
        if isGuide {
            let variable = env ?? "API_KEY"
            let addressVariable = capture(#"\$\{?([A-Za-z_][A-Za-z0-9_]*(?:BASE_URL|ENDPOINT))\}?"#, in: normalized)
                ?? variable.replacingOccurrences(of: #"(?:API_KEY|TOKEN|KEY)$"#, with: "BASE_URL", options: .regularExpression)
            let name = sourceURL.map { ($0.host ?? "自定义服务").replacingOccurrences(of: "www.", with: "") } ?? variable.replacingOccurrences(of: "_API_KEY", with: "").replacingOccurrences(of: "_TOKEN", with: "")
            let base = capture(#"(?i)curl\s+["']?(https?://[^\s"'$<>]+)"#, in: normalized).flatMap { validAPIURL($0) } ?? ""
            let auth = header.map { Authentication(kind: .header, fieldName: $0) } ?? Authentication(kind: .bearer)
            let actual = assignedValue(variable, in: normalized).flatMap { isPlaceholder($0) ? nil : $0 } ?? ""
            return [NoteImportCandidate(draft: ServiceDraft(name: name, documentationURL: sourceURL?.absoluteString ?? "",
                authentication: auth, allowsIncomplete: true, requiresBaseURL: base.isEmpty,
                environmentVariable: variable, baseURL: base, baseURLVariable: addressVariable,
                credentials: [CredentialDraft(environmentVariable: variable, secret: actual)]),
                sourcePreview: "已从接入说明识别服务参数；示例占位符不会保存为 Key。",
                automaticAdditions: ["已识别接入说明与鉴权方式", "缺少的 Key 可稍后补充"]) ]
        }
        if let sourceURL {
            let host = (sourceURL.host ?? "自定义服务").replacingOccurrences(of: "www.", with: "")
            let variable = ServiceDraft.suggestedEnvironmentName(for: host.components(separatedBy: ".").first ?? host)
            return [NoteImportCandidate(draft: ServiceDraft(name: host, documentationURL: sourceURL.absoluteString,
                allowsIncomplete: true, environmentVariable: variable, credentials: [CredentialDraft(environmentVariable: variable)]),
                sourcePreview: "已读取公开页面；原文不保存。", automaticAdditions: ["已保存来源网址", "页面未给出明确 API 配置，可先保存服务，稍后补充"]) ]
        }
        return NoteImportParser.parse(text)
    }

    private static func openAPI(_ text: String, sourceURL: URL?) -> NoteImportCandidate? {
        guard let data = text.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["openapi"] != nil || json["swagger"] != nil else { return nil }
        let info = json["info"] as? [String: Any] ?? [:]
        let name = info["title"] as? String ?? sourceURL?.host ?? "API 服务"
        let env = ServiceDraft.suggestedEnvironmentName(for: name)
        let servers = json["servers"] as? [[String: Any]] ?? []
        let base = (servers.first?["url"] as? String).flatMap { validAPIURL($0) } ?? ""
        let components = json["components"] as? [String: Any] ?? [:]
        let schemes = components["securitySchemes"] as? [String: [String: Any]] ?? json["securityDefinitions"] as? [String: [String: Any]] ?? [:]
        var auth = Authentication()
        for key in schemes.keys.sorted() {
            let scheme = schemes[key]!
            if scheme["type"] as? String == "apiKey", let field = scheme["name"] as? String, ["header", "query"].contains(scheme["in"] as? String ?? "") {
                auth = Authentication(kind: scheme["in"] as? String == "query" ? .query : .header, fieldName: field); break
            }
            if (scheme["scheme"] as? String)?.lowercased() == "bearer" { auth = Authentication(kind: .bearer); break }
        }
        return NoteImportCandidate(draft: ServiceDraft(name: name, summary: info["description"] as? String ?? "",
            documentationURL: sourceURL?.absoluteString ?? "", authentication: auth, allowsIncomplete: true,
            requiresBaseURL: base.isEmpty, environmentVariable: env, baseURL: base, baseURLVariable: env.replacingOccurrences(of: "_API_KEY", with: "_BASE_URL"), credentials: [CredentialDraft(environmentVariable: env)]),
            sourcePreview: "已读取 OpenAPI 接口说明。", automaticAdditions: ["已从 OpenAPI 自动填写服务名称、地址与鉴权方式"])
    }

    private static func assignedValue(_ name: String, in text: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        guard var value = capture("(?m)^\\s*(?:export\\s+)?" + escaped + "\\s*[:=]\\s*([^\\r\\n]+)$", in: text)?.trimmingCharacters(in: .whitespaces) else { return nil }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) { value = String(value.dropFirst().dropLast()) }
        return value
    }

    private static func validAPIURL(_ value: String) -> String? {
        guard !isPlaceholder(value), let c = URLComponents(string: value), ["http", "https"].contains(c.scheme ?? ""), c.host != nil,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil else { return nil }
        return value
    }

    public static func isPlaceholder(_ value: String) -> Bool {
        value.isEmpty || value.contains("$") || value.contains("{{") || value.contains("<") || value.contains("[") || value.contains("•") || value.contains("...") || value.range(of: #"(?i)^(?:your[-_ ]|example|replace|placeholder|sk-xxx|xxx|请|填写|此处)"#, options: .regularExpression) != nil
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
