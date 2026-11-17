import Foundation

public struct CurlExecution: Sendable {
    public var arguments: [String]
    public var containsInsecureTLS: Bool

    public init(arguments: [String], containsInsecureTLS: Bool) {
        self.arguments = arguments
        self.containsInsecureTLS = containsInsecureTLS
    }
}

public enum SafeCurl {
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func isReadOnly(_ template: String) -> Bool {
        guard let parsed = try? parse(template) else { return false }
        let arguments = parsed.arguments
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            if bodyOptions.contains(option) { return false }
            if optionsWithValues.contains(option) {
                if option == "--request", !["GET", "HEAD"].contains(arguments[index + 1].uppercased()) { return false }
                index += 2
            } else {
                index += 1
            }
        }
        return true
    }

    public static func encodedQuerySecret(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? ""
    }

    public static func redactSecrets(_ text: String, values: [String]) -> String {
        var value = text
        let variants = values.filter { !$0.isEmpty }.flatMap { secret -> [String] in
            let escaped = String(data: (try? JSONEncoder().encode(secret)) ?? Data(), encoding: .utf8) ?? ""
            return [secret, encodedQuerySecret(secret), escaped.count >= 2 ? String(escaped.dropFirst().dropLast()) : secret]
        }
        for secret in Set(variants).filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) {
            value = value.replacingOccurrences(of: secret, with: "[REDACTED]")
        }
        return value
    }

    // Unknown options are rejected, rather than relying on a blacklist of
    // curl's many aliases, abbreviations and file-reading argument forms.
    private static let optionsWithValues: Set<String> = [
        "--request", "--header", "--data", "--data-raw", "--data-binary",
        "--data-urlencode", "--json", "--user", "--user-agent", "--referer",
        "--connect-timeout", "--max-time", "--retry", "--retry-delay",
        "--proxy", "--proxy-user", "--resolve", "--url", "--form-string",
    ]
    private static let bodyOptions: Set<String> = [
        "--data", "--data-raw", "--data-binary", "--data-urlencode", "--json", "--form-string",
    ]
    private static let flagOptions: Set<String> = [
        "--head", "--get", "--silent", "--show-error", "--insecure", "--location",
        "--compressed", "--fail", "--fail-with-body", "--http1.0", "--http1.1",
        "--http2", "--ipv4", "--ipv6", "--globoff", "--disable",
    ]
    private static let shortOptions: [Character: String] = [
        "X": "--request", "H": "--header", "d": "--data", "u": "--user",
        "A": "--user-agent", "e": "--referer", "x": "--proxy", "U": "--proxy-user",
        "I": "--head", "G": "--get", "s": "--silent", "S": "--show-error",
        "k": "--insecure", "L": "--location", "f": "--fail", "0": "--http1.0",
        "4": "--ipv4", "6": "--ipv6", "g": "--globoff", "q": "--disable",
    ]

    public static func parse(_ command: String) throws -> CurlExecution {
        let tokens = try shellWords(command)
        guard let executable = tokens.first,
              executable == "curl" || executable == "/usr/bin/curl" else {
            throw WhereKeyError.unsafeCurl("请求必须以 curl 开头")
        }
        var arguments: [String] = []
        var urlCount = 0
        var index = 1
        while index < tokens.count {
            let token = tokens[index]
            if token.hasPrefix("-") {
                var option: String
                var attachedValue: String?
                if token.hasPrefix("--") {
                    if let equals = token.firstIndex(of: "=") {
                        option = String(token[..<equals])
                        attachedValue = String(token[token.index(after: equals)...])
                    } else {
                        option = token
                    }
                } else {
                    guard token.count >= 2, let canonical = shortOptions[Array(token)[1]] else {
                        throw WhereKeyError.unsafeCurl("请求包含不支持的 curl 参数")
                    }
                    option = canonical
                    if token.count > 2 {
                        if flagOptions.contains(option) {
                            // Preserve safe bundles such as -sS / -sSL, but
                            // reject the entire token if any flag is unknown
                            // or takes a value (notably -o / -K / -T / -F).
                            let bundle = try token.dropFirst().map { flag -> String in
                                guard let name = shortOptions[flag], flagOptions.contains(name) else {
                                    throw WhereKeyError.unsafeCurl("请将带值的 curl 短参数分别填写")
                                }
                                return name
                            }
                            arguments.append(contentsOf: bundle)
                            index += 1
                            continue
                        }
                        // Preserve common -XPOST / -HHeader / -dDATA forms.
                        attachedValue = String(token.dropFirst(2))
                    }
                }
                if optionsWithValues.contains(option) {
                    let value: String
                    if let attachedValue { value = attachedValue }
                    else {
                        index += 1
                        guard index < tokens.count else { throw WhereKeyError.unsafeCurl("curl 参数缺少值") }
                        value = tokens[index]
                    }
                    try validate(value: value, for: option)
                    if option == "--url" { urlCount += 1 }
                    arguments.append(contentsOf: [option, value])
                } else if flagOptions.contains(option), attachedValue == nil {
                    arguments.append(option)
                } else {
                    throw WhereKeyError.unsafeCurl("请求包含不支持或可能访问本地文件的 curl 参数")
                }
            } else {
                try validateURL(token)
                urlCount += 1
                arguments.append(token)
            }
            index += 1
        }
        guard urlCount == 1 else {
            throw WhereKeyError.unsafeCurl("请求必须且只能包含一个 http/https URL")
        }
        let insecure = arguments.contains("--insecure")
        arguments.append(contentsOf: ["--silent", "--show-error"])
        return CurlExecution(arguments: arguments, containsInsecureTLS: insecure)
    }

    // Validate again after placeholder expansion: a secret can become an
    // @file value even when the original template was safe to tokenize.
    // Internal so tests can exercise expansion semantics without executing curl.
    static func validateExpandedArguments(_ arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            if optionsWithValues.contains(option) {
                guard index + 1 < arguments.count else { throw WhereKeyError.unsafeCurl("curl 参数缺少值") }
                try validate(value: arguments[index + 1], for: option)
                index += 2
            } else if flagOptions.contains(option) {
                index += 1
            } else {
                try validateURL(option)
                index += 1
            }
        }
    }

    private static func validateURL(_ value: String) throws {
        guard let url = URLComponents(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              !(url.host ?? "").isEmpty,
              !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else {
            throw WhereKeyError.unsafeCurl("只允许单个 http/https URL")
        }
    }

    private static func validate(value: String, for option: String) throws {
        if option == "--url" { try validateURL(value) }
        if option == "--header" {
            guard !value.hasPrefix("@"), !value.contains("\r"), !value.contains("\n") else {
                throw WhereKeyError.unsafeCurl("请求 Header 不允许读取本地文件或包含换行")
            }
        }
        if ["--data", "--data-binary", "--json"].contains(option), value.hasPrefix("@") {
            throw WhereKeyError.unsafeCurl("请求正文不允许读取本地文件")
        }
        if option == "--data-urlencode", let at = value.firstIndex(of: "@") {
            // curl interprets both @file and name@file as a local file. An @
            // after the first '=' is literal form content and remains valid.
            guard let equals = value.firstIndex(of: "="), equals < at else {
                throw WhereKeyError.unsafeCurl("URL 编码正文不允许读取本地文件")
            }
        }
        if option == "--request" {
            guard !value.isEmpty, value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$%&'*+-.^_`|~").contains($0) }) else {
                throw WhereKeyError.unsafeCurl("HTTP 请求方法无效")
            }
        }
    }

    public static func shellWords(_ input: String) throws -> [String] {
        enum State { case normal, single, double }
        var state: State = .normal
        var result: [String] = []
        var current = ""
        var escaping = false
        var hasToken = false
        let characters = Array(input)
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if escaping {
                if character != "\n" { current.append(character); hasToken = true }
                escaping = false
                index += 1
                continue
            }
            switch state {
            case .normal:
                if character == "\\" { escaping = true; hasToken = true }
                else if character == "'" { state = .single; hasToken = true }
                else if character == "\"" { state = .double; hasToken = true }
                else if character.isWhitespace {
                    if hasToken { result.append(current); current = ""; hasToken = false }
                } else if "|;&><`".contains(character) {
                    throw WhereKeyError.unsafeCurl("curl 中不能包含 shell 管道、重定向或控制符")
                } else if character == "$", index + 1 < characters.count, characters[index + 1] == "(" {
                    throw WhereKeyError.unsafeCurl("curl 中不能包含命令替换")
                } else {
                    current.append(character); hasToken = true
                }
            case .single:
                if character == "'" { state = .normal }
                else { current.append(character); hasToken = true }
            case .double:
                if character == "\"" { state = .normal }
                else if character == "\\" { escaping = true }
                else if character == "`" || (character == "$" && index + 1 < characters.count && characters[index + 1] == "(") {
                    throw WhereKeyError.unsafeCurl("curl 中不能包含命令替换")
                } else { current.append(character); hasToken = true }
            }
            index += 1
        }
        guard state == .normal, !escaping else { throw WhereKeyError.unsafeCurl("curl 引号或转义不完整") }
        if hasToken { result.append(current) }
        return result
    }

    public static func redacted(_ template: String) -> String {
        var value = template
        let patterns = [
            #"(?i)((?:Authorization|Proxy-Authorization)\s*:\s*(?:Bearer\s+|Basic\s+)?)([^\s'\"]+)"#,
            #"(?i)((?:[a-z0-9_-]*(?:api[-_]?key|token|secret|password))\s*:\s*)([^\s'\"]+)"#,
            #"(?i)((?:-H|--header)\s+['\"][^:'\"]+:\s*)([^'\"]+)"#,
            #"([?&][^=&#\s'\"]+=)([^&#\s'\"]+)"#,
            #"(?i)([\"'](?:[a-z0-9_-]*(?:key|token|secret|password))[\"']\s*:\s*[\"'])([^\"']+)"#,
            #"(?i)((?:-u|--user|--proxy-user)\s+)(?:'[^']*'|\"[^\"]*\"|[^\s]+)"#,
            #"(?i)((?:-d|--data|--data-raw|--data-urlencode|--json|--form-string)\s+)(?:'[^']*'|\"[^\"]*\"|[^\s]+)"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(value.startIndex..., in: value)
            value = regex.stringByReplacingMatches(in: value, range: range, withTemplate: "$1[REDACTED]")
        }
        value = value.replacingOccurrences(
            of: #"\{\{secret:[^}]+\}\}"#,
            with: "[REDACTED]",
            options: .regularExpression
        )
        return value
    }

    public static func extractFirstSecret(from command: String, alias: String) -> (template: String, secret: String)? {
        let patterns = [
            #"(?i)(Authorization\s*:\s*Bearer\s+)([^\s'\"]+)"#,
            #"(?i)((?:[a-z0-9_-]*(?:api[-_]?key|token|secret))\s*:\s*)([^\s'\"]+)"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let fullRange = NSRange(command.startIndex..., in: command)
            guard let match = regex.firstMatch(in: command, range: fullRange),
                  match.numberOfRanges >= 3,
                  let secretRange = Range(match.range(at: 2), in: command) else { continue }
            let secret = String(command[secretRange])
            var template = command
            template.replaceSubrange(secretRange, with: "{{secret:\(alias)}}")
            return (template, secret)
        }
        return nil
    }
}

public final class CurlValidator {
    public init() {}

    public func execute(template: String, secrets: [String: String], rule: ValidationRule, returnBody: Bool) throws -> CheckResult {
        // Parse the request shape before inserting secrets, so quotes and spaces in
        // a credential cannot introduce curl arguments or change the HTTP method.
        let parsed = try SafeCurl.parse(template)
        let placeholderPattern = try NSRegularExpression(pattern: #"\{\{(key(?::url)?|secret:[^}]+)\}\}"#)
        let arguments = try parsed.arguments.enumerated().map { index, argument -> String in
            var value = argument
            let matches = placeholderPattern.matches(in: argument, range: NSRange(argument.startIndex..., in: argument))
            for match in matches.reversed() {
                let token = String(argument[Range(match.range(at: 1), in: argument)!])
                let alias = token.hasPrefix("secret:") ? String(token.dropFirst(7)) : "__default"
                guard let secret = secrets[alias] else { throw WhereKeyError.invalidInput("验证请求引用了不存在的 Key") }
                value.replaceSubrange(Range(match.range, in: value)!, with: token == "key:url" ? SafeCurl.encodedQuerySecret(secret) : secret)
            }
            if index > 0, ["-H", "--header"].contains(parsed.arguments[index - 1]),
               value.unicodeScalars.contains(where: { $0.value == 10 || $0.value == 13 }) {
                throw WhereKeyError.invalidInput("Header 中的 Key 不能包含换行")
            }
            return value
        }
        try SafeCurl.validateExpandedArguments(arguments)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        // Ignore ~/.curlrc and prevent URL globbing or redirects to file and
        // other non-HTTP protocols, regardless of curl's local defaults.
        process.arguments = ["--disable", "--globoff", "--proto", "=http,https", "--proto-redir", "=http,https"] + arguments + [
            "--max-time", String(max(1, min(rule.timeoutSeconds, 60))),
            "--max-filesize", "1048576",
            "--write-out", "\n__WHEREKEY_STATUS__:%{http_code}",
        ]
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        let started = Date()
        let outputBox = DataBox()
        let errorBox = DataBox()
        let readers = DispatchGroup()
        try process.run()
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outputBox.value = outputPipe.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errorBox.value = errorPipe.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }
        process.waitUntilExit()
        readers.wait()
        let elapsed = Int(Date().timeIntervalSince(started) * 1_000)
        let output = String(data: outputBox.value, encoding: .utf8) ?? ""
        let error = String(data: errorBox.value, encoding: .utf8) ?? ""
        let marker = "\n__WHEREKEY_STATUS__:"
        let markerRange = output.range(of: marker, options: .backwards)
        let body = markerRange.map { String(output[..<$0.lowerBound]) } ?? output
        let statusCode = markerRange.flatMap { Int(output[$0.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)) }

        guard process.terminationStatus == 0 else {
            let status: HealthStatus = statusCode == 401 ? .invalid : statusCode == 403 ? .forbidden : statusCode == 429 ? .rateLimited : .unavailable
            return CheckResult(status: status, httpStatus: statusCode, elapsedMilliseconds: elapsed, message: error.isEmpty ? "请求失败" : SafeCurl.redactSecrets(error.trimmingCharacters(in: .whitespacesAndNewlines), values: Array(secrets.values)))
        }
        guard let statusCode, statusMatches(statusCode, expression: rule.acceptedStatusCodes) else {
            let status: HealthStatus = statusCode == 401 ? .invalid : statusCode == 403 ? .forbidden : statusCode == 429 ? .rateLimited : .failed
            return CheckResult(status: status, httpStatus: statusCode, elapsedMilliseconds: elapsed, message: "HTTP 状态不符合 \(rule.acceptedStatusCodes)", responsePreview: returnBody ? preview(body, secrets: secrets) : "")
        }
        if !rule.bodyContains.isEmpty, !body.contains(rule.bodyContains) {
            return CheckResult(status: .failed, httpStatus: statusCode, elapsedMilliseconds: elapsed, message: "响应正文不包含指定文本", responsePreview: returnBody ? preview(body, secrets: secrets) : "")
        }
        if !rule.jsonPath.isEmpty {
            guard jsonMatches(body, path: rule.jsonPath, expected: rule.jsonExpectedValue) else {
                return CheckResult(status: .failed, httpStatus: statusCode, elapsedMilliseconds: elapsed, message: "JSON 字段断言失败", responsePreview: returnBody ? preview(body, secrets: secrets) : "")
            }
        }
        let health: HealthStatus = parsed.containsInsecureTLS ? .tlsUnverified : .valid
        return CheckResult(status: health, httpStatus: statusCode, elapsedMilliseconds: elapsed, message: health.displayName, responsePreview: returnBody ? preview(body, secrets: secrets) : "")
    }

    private func statusMatches(_ status: Int, expression: String) -> Bool {
        for part in expression.split(separator: ",") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if let dash = trimmed.firstIndex(of: "-"),
               let lower = Int(trimmed[..<dash]), let upper = Int(trimmed[trimmed.index(after: dash)...]),
               lower <= upper, (lower...upper).contains(status) { return true }
            if Int(trimmed) == status { return true }
        }
        return false
    }

    private func jsonMatches(_ body: String, path: String, expected: String) -> Bool {
        guard let data = body.data(using: .utf8),
              var current = try? JSONSerialization.jsonObject(with: data) else { return false }
        for component in path.split(separator: ".") {
            if let dictionary = current as? [String: Any], let next = dictionary[String(component)] {
                current = next
            } else { return false }
        }
        if expected.isEmpty { return true }
        if let bool = current as? Bool { return String(bool) == expected.lowercased() }
        if let number = current as? NSNumber { return number.stringValue == expected }
        return String(describing: current) == expected
    }

    private func preview(_ body: String, secrets: [String: String]) -> String {
        String(SafeCurl.redactSecrets(body, values: Array(secrets.values)).prefix(4_096))
    }
}

private final class DataBox: @unchecked Sendable {
    var value = Data()
}
