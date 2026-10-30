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
    private static let optionsWithValues: Set<String> = [
        "-X", "--request", "-H", "--header", "-d", "--data", "--data-raw",
        "--data-urlencode", "--json", "-u", "--user", "-A", "--user-agent",
        "-e", "--referer", "--connect-timeout", "--max-time", "--retry",
        "--retry-delay", "--proxy", "--proxy-user", "--cacert", "--cert",
        "--key", "--resolve", "--url", "--form-string",
    ]

    private static let forbiddenOptions: Set<String> = [
        "-o", "--output", "-O", "--remote-name", "-K", "--config", "-T",
        "--upload-file", "--trace", "--trace-ascii", "--trace-config", "--netrc",
        "--netrc-file", "-c", "--cookie-jar", "--dump-header", "-D", "-w",
        "--write-out", "--output-dir", "--remote-header-name",
    ]

    public static func parse(_ command: String) throws -> CurlExecution {
        let tokens = try shellWords(command)
        guard let executable = tokens.first,
              executable == "curl" || executable == "/usr/bin/curl" else {
            throw WhereKeyError.unsafeCurl("请求必须以 curl 开头")
        }
        var arguments = Array(tokens.dropFirst())
        guard !arguments.isEmpty else { throw WhereKeyError.unsafeCurl("curl 缺少 URL") }

        var urlCount = 0
        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            if forbiddenOptions.contains(token) {
                throw WhereKeyError.unsafeCurl("检查请求不允许参数 \(token)")
            }
            if token.hasPrefix("@") {
                throw WhereKeyError.unsafeCurl("检查请求不允许读取本地文件")
            }
            if token.hasPrefix("http://") || token.hasPrefix("https://") {
                urlCount += 1
            } else if token.contains("://") && !token.hasPrefix("http://") && !token.hasPrefix("https://") {
                throw WhereKeyError.unsafeCurl("只允许 http/https URL")
            }
            if optionsWithValues.contains(token) {
                guard index + 1 < arguments.count else {
                    throw WhereKeyError.unsafeCurl("参数 \(token) 缺少值")
                }
                let value = arguments[index + 1]
                if token.hasPrefix("--data") || token == "-d" || token == "--json" {
                    if value.hasPrefix("@") { throw WhereKeyError.unsafeCurl("请求正文不允许读取本地文件") }
                }
                if token == "--url" {
                    guard value.hasPrefix("http://") || value.hasPrefix("https://") else {
                        throw WhereKeyError.unsafeCurl("只允许 http/https URL")
                    }
                    urlCount += 1
                }
                index += 2
            } else {
                index += 1
            }
        }
        guard urlCount == 1 else {
            throw WhereKeyError.unsafeCurl("检查请求必须且只能包含一个 http/https URL")
        }
        let insecure = arguments.contains("-k") || arguments.contains("--insecure")
        arguments.append(contentsOf: ["--silent", "--show-error"])
        return CurlExecution(arguments: arguments, containsInsecureTLS: insecure)
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
            #"(?i)(Authorization\s*:\s*Bearer\s+)([^\s'\"]+)"#,
            #"(?i)((?:x-api-key|api-key)\s*:\s*)([^\s'\"]+)"#,
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
            #"(?i)((?:x-api-key|api-key)\s*:\s*)([^\s'\"]+)"#,
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
        var resolved = template
        for (alias, secret) in secrets {
            resolved = resolved.replacingOccurrences(of: "{{secret:\(alias)}}", with: secret)
        }
        if let defaultSecret = secrets["__default"] {
            resolved = resolved.replacingOccurrences(of: "{{key}}", with: defaultSecret)
        }
        let parsed = try SafeCurl.parse(resolved)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = parsed.arguments + [
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
            return CheckResult(status: .invalid, httpStatus: statusCode, elapsedMilliseconds: elapsed, message: error.isEmpty ? "请求失败" : error.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let statusCode, statusMatches(statusCode, expression: rule.acceptedStatusCodes) else {
            return CheckResult(status: .invalid, httpStatus: statusCode, elapsedMilliseconds: elapsed, message: "HTTP 状态不符合 \(rule.acceptedStatusCodes)", responsePreview: returnBody ? preview(body, secrets: secrets) : "")
        }
        if !rule.bodyContains.isEmpty, !body.contains(rule.bodyContains) {
            return CheckResult(status: .invalid, httpStatus: statusCode, elapsedMilliseconds: elapsed, message: "响应正文不包含指定文本", responsePreview: returnBody ? preview(body, secrets: secrets) : "")
        }
        if !rule.jsonPath.isEmpty {
            guard jsonMatches(body, path: rule.jsonPath, expected: rule.jsonExpectedValue) else {
                return CheckResult(status: .invalid, httpStatus: statusCode, elapsedMilliseconds: elapsed, message: "JSON 字段断言失败", responsePreview: returnBody ? preview(body, secrets: secrets) : "")
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
               (lower...upper).contains(status) { return true }
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
        var value = String(body.prefix(4_096))
        for secret in secrets.values where !secret.isEmpty {
            value = value.replacingOccurrences(of: secret, with: "[REDACTED]")
        }
        return value
    }
}

private final class DataBox: @unchecked Sendable {
    var value = Data()
}
