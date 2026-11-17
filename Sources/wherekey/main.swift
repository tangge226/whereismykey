import Darwin
import Foundation
import WhereKeyCore

private enum CLIError: LocalizedError {
    case usage(String)
    var errorDescription: String? {
        switch self { case .usage(let value): return value }
    }
}

private let usage = """
WhereKey — 本地 API 服务目录

用法：
  wherekey catalog [--json]
  wherekey describe --service NAME [--json]
  wherekey run --service NAME [--key ALIAS] -- COMMAND [ARGS...]
  wherekey call --service NAME [--key ALIAS] [--json]
  wherekey check --service NAME [--key ALIAS] [--json]
"""

private struct ParsedOptions {
    var service: String?
    var keyAlias: String?
    var json = false
    var command: [String] = []
}

private func parseOptions(_ arguments: [String], permitsCommand: Bool = false) throws -> ParsedOptions {
    var result = ParsedOptions()
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        if argument == "--", permitsCommand {
            result.command = Array(arguments.dropFirst(index + 1))
            break
        }
        switch argument {
        case "--service":
            guard index + 1 < arguments.count else { throw CLIError.usage("--service 缺少名称") }
            result.service = arguments[index + 1]; index += 2
        case "--key":
            guard index + 1 < arguments.count else { throw CLIError.usage("--key 缺少别名") }
            result.keyAlias = arguments[index + 1]; index += 2
        case "--json": result.json = true; index += 1
        default: throw CLIError.usage("未知参数：\(argument)")
        }
    }
    return result
}

private func send(_ request: IPCRequest) throws -> IPCResponse {
    let client = IPCClient()
    do {
        return try validated(client.send(request))
    } catch WhereKeyError.ipcConnection {
        launchApplication()
        for _ in 0..<40 {
            usleep(100_000)
            do { return try validated(client.send(request)) }
            catch WhereKeyError.ipcConnection { continue }
        }
        throw WhereKeyError.ipcConnection("无法连接 WhereKey。请先把 WhereKey.app 放入 Applications 并打开一次。")
    }
}

private func validated(_ response: IPCResponse) throws -> IPCResponse {
    guard response.ok else { throw WhereKeyError.unavailable(response.error ?? "WhereKey 请求失败") }
    return response
}

private func launchApplication() {
    let environment = ProcessInfo.processInfo.environment
    let candidates = [
        environment["WHEREKEY_APP_PATH"],
        "/Applications/WhereKey.app",
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/WhereKey.app").path,
    ].compactMap { $0 }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    if let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
        process.arguments = ["-gj", path]
    } else {
        process.arguments = ["-gja", "WhereKey"]
    }
    try? process.run()
    process.waitUntilExit()
}

private func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

private final class RedactingRelay {
    private var pending = Data()
    private let secrets: [Data]
    private let maximumLength: Int
    private let output: FileHandle
    private let lock = NSLock()
    private let replacement = Data("[REDACTED]".utf8)

    init(secrets: [String], output: FileHandle) {
        self.secrets = secrets.filter { !$0.isEmpty }.compactMap { $0.data(using: .utf8) }.sorted { $0.count > $1.count }
        self.maximumLength = self.secrets.map(\.count).max() ?? 1
        self.output = output
    }

    func consume(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        pending.append(data)
        drain(finishing: false)
    }

    func finish() {
        lock.lock(); defer { lock.unlock() }
        drain(finishing: true)
    }

    private func drain(finishing: Bool) {
        var emitted = Data()
        while !pending.isEmpty && (finishing || pending.count >= maximumLength) {
            if let secret = secrets.first(where: { pending.starts(with: $0) }) {
                emitted.append(replacement)
                pending.removeFirst(secret.count)
            } else {
                emitted.append(pending.removeFirst())
            }
        }
        if !emitted.isEmpty { output.write(emitted) }
    }
}

private func resolveExecutable(_ value: String, cwd: URL, environment: [String: String]) throws -> URL {
    if value.contains("/") {
        let url = value.hasPrefix("/") ? URL(fileURLWithPath: value) : cwd.appendingPathComponent(value)
        guard FileManager.default.isExecutableFile(atPath: url.path) else { throw CLIError.usage("命令不可执行：\(value)") }
        return url
    }
    for directory in (environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":") {
        let url = URL(fileURLWithPath: String(directory)).appendingPathComponent(value)
        if FileManager.default.isExecutableFile(atPath: url.path) { return url }
    }
    throw CLIError.usage("找不到命令：\(value)")
}

private func runCommand(_ command: [String], prepared: PreparedRun) throws -> Int32 {
    guard let executable = command.first else { throw CLIError.usage("-- 后缺少要运行的命令") }
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    var environment = ProcessInfo.processInfo.environment
    for (name, value) in prepared.environment { environment[name] = value }
    let process = Process()
    process.executableURL = try resolveExecutable(executable, cwd: cwd, environment: environment)
    process.arguments = Array(command.dropFirst())
    process.environment = environment
    process.currentDirectoryURL = cwd
    process.standardInput = FileHandle.standardInput
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    let stdoutRelay = RedactingRelay(secrets: prepared.secretsForRedaction, output: .standardOutput)
    let stderrRelay = RedactingRelay(secrets: prepared.secretsForRedaction, output: .standardError)
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        while true {
            let data = stdoutPipe.fileHandleForReading.readData(ofLength: 4_096)
            if data.isEmpty { break }
            stdoutRelay.consume(data)
        }
        stdoutRelay.finish(); group.leave()
    }
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        while true {
            let data = stderrPipe.fileHandleForReading.readData(ofLength: 4_096)
            if data.isEmpty { break }
            stderrRelay.consume(data)
        }
        stderrRelay.finish(); group.leave()
    }
    try process.run()
    process.waitUntilExit()
    group.wait()
    return process.terminationStatus
}

do {
    var arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first else { throw CLIError.usage(usage) }
    arguments.removeFirst()
    switch command {
    case "catalog":
        let options = try parseOptions(arguments)
        let response = try send(IPCRequest(action: "catalog"))
        let services = response.catalog ?? []
        if options.json { try printJSON(services) }
        else {
            for service in services {
                let keyNames = service.credentials.map { $0.alias + ($0.isDefault ? "（默认）" : "") }.joined(separator: ", ")
                print("\(service.name)\t\(service.kind.displayName)\t\(service.setupMessage ?? service.status.displayName)\t\(keyNames)")
            }
        }
    case "describe":
        let options = try parseOptions(arguments)
        guard let service = options.service else { throw CLIError.usage("请提供 --service NAME") }
        let value = try send(IPCRequest(action: "describe", service: service)).description!
        try printJSON(value)
    case "run":
        let options = try parseOptions(arguments, permitsCommand: true)
        guard let service = options.service else { throw CLIError.usage("请提供 --service NAME") }
        let response = try send(IPCRequest(action: "prepareRun", service: service, keyAlias: options.keyAlias, cwd: FileManager.default.currentDirectoryPath))
        guard let prepared = response.preparedRun else { throw WhereKeyError.unavailable("WhereKey 未返回运行配置") }
        exit(try runCommand(options.command, prepared: prepared))
    case "call":
        let options = try parseOptions(arguments)
        guard let service = options.service else { throw CLIError.usage("请提供 --service NAME") }
        let result = try send(IPCRequest(action: "call", service: service, keyAlias: options.keyAlias, cwd: FileManager.default.currentDirectoryPath)).checkResult!
        if options.json { try printJSON(result) }
        else {
            if !result.responsePreview.isEmpty { print(result.responsePreview) }
            FileHandle.standardError.write(Data("\(result.status.displayName) · HTTP \(result.httpStatus.map(String.init) ?? "-") · \(result.elapsedMilliseconds)ms\n".utf8))
        }
        if result.status.isFailure { exit(1) }
    case "check":
        let options = try parseOptions(arguments)
        guard let service = options.service else { throw CLIError.usage("请提供 --service NAME") }
        let result = try send(IPCRequest(action: "check", service: service, keyAlias: options.keyAlias)).checkResult!
        if options.json { try printJSON(result) }
        else { print("\(result.status.displayName) · \(result.message) · \(result.elapsedMilliseconds)ms") }
        if result.status.isFailure { exit(1) }
    case "help", "--help", "-h": print(usage)
    default: throw CLIError.usage("未知命令：\(command)\n\n\(usage)")
    }
} catch {
    FileHandle.standardError.write(Data("wherekey: \(error.localizedDescription)\n".utf8))
    exit(2)
}
