import Darwin
import Foundation

public struct IPCRequest: Codable, Sendable {
    public var action: String
    public var service: String?
    public var keyAlias: String?
    public var cwd: String?

    public init(action: String, service: String? = nil, keyAlias: String? = nil, cwd: String? = nil) {
        self.action = action
        self.service = service
        self.keyAlias = keyAlias
        self.cwd = cwd
    }
}

public struct IPCResponse: Codable, Sendable {
    public var ok: Bool
    public var error: String?
    public var catalog: [CatalogService]?
    public var description: ServiceDescription?
    public var preparedRun: PreparedRun?
    public var checkResult: CheckResult?
    public var checkResults: [NamedCheckResult]?

    public init(
        ok: Bool,
        error: String? = nil,
        catalog: [CatalogService]? = nil,
        description: ServiceDescription? = nil,
        preparedRun: PreparedRun? = nil,
        checkResult: CheckResult? = nil,
        checkResults: [NamedCheckResult]? = nil
    ) {
        self.ok = ok
        self.error = error
        self.catalog = catalog
        self.description = description
        self.preparedRun = preparedRun
        self.checkResult = checkResult
        self.checkResults = checkResults
    }
}

public struct NamedCheckResult: Codable, Sendable {
    public var service: String
    public var result: CheckResult

    public init(service: String, result: CheckResult) {
        self.service = service
        self.result = result
    }
}

public enum IPCPath {
    public static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["WHEREKEY_SOCKET_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("wherekey-\(getuid())", isDirectory: true)
    }

    public static var socket: URL { directory.appendingPathComponent("wherekey.sock") }
}

public struct IPCConfiguration: Sendable {
    public var directoryURL: URL
    public var requestTimeout: TimeInterval
    public var responseTimeout: TimeInterval
    public var writeTimeout: TimeInterval
    public var maxConnections: Int

    public init(directoryURL: URL = IPCPath.directory, requestTimeout: TimeInterval = 5,
                responseTimeout: TimeInterval = 65, writeTimeout: TimeInterval = 5, maxConnections: Int = 8) {
        self.directoryURL = directoryURL
        self.requestTimeout = requestTimeout
        self.responseTimeout = responseTimeout
        self.writeTimeout = writeTimeout
        self.maxConnections = maxConnections
    }

    var socketURL: URL { directoryURL.appendingPathComponent("wherekey.sock") }
    func validate() throws {
        guard directoryURL.isFileURL, (1...32).contains(maxConnections),
              [requestTimeout, responseTimeout, writeTimeout].allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 120 }) else {
            throw WhereKeyError.invalidInput("IPC 配置无效")
        }
    }
}

public final class IPCServer: @unchecked Sendable {
    public typealias Handler = @Sendable (IPCRequest) -> IPCResponse
    private let handler: Handler
    private let configuration: IPCConfiguration
    private let trustedPeers: [URL]?
    private let lifecycle = NSLock()
    private var context: IPCServerContext?
    private let queue = DispatchQueue(label: "com.wherekey.ipc", qos: .userInitiated, attributes: .concurrent)

    public init(configuration: IPCConfiguration = IPCConfiguration(), trustedPeerExecutables: [URL]? = nil,
                handler: @escaping Handler) {
        self.configuration = configuration
        self.trustedPeers = trustedPeerExecutables
        self.handler = handler
    }

    deinit { stop() }

    public func start() throws {
        lifecycle.lock(); defer { lifecycle.unlock() }
        guard context == nil else { return }
        try configuration.validate()
        let verifier = try IPCPeerVerifier(role: .server, trustedExecutables: trustedPeers)
        let next = try IPCServerContext(configuration: configuration)
        context = next
        let handler = handler, configuration = configuration, queue = queue
        // Capture the generation, never a mutable descriptor on self.
        queue.async {
            defer { next.finish() }
            while !next.isStopped {
                var ready = pollfd(fd: next.listener, events: Int16(POLLIN), revents: 0)
                let result = Darwin.poll(&ready, 1, 100)
                if result < 0 { if errno == EINTR { continue }; break }
                if result == 0 { continue }
                if next.isStopped { break }
                let client = Darwin.accept(next.listener, nil, nil)
                if client < 0 {
                    if [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
                    break
                }
                do { try IPCTransport.configureDescriptor(client) }
                catch { Darwin.close(client); continue }
                guard next.register(client) else { Darwin.close(client); continue }
                queue.async {
                    defer { next.release(client) }
                    do {
                        // Authenticate before decoding even a catalog request.
                        try verifier.verify(socket: client)
                        let data = try IPCTransport.readMessage(from: client, timeout: configuration.requestTimeout)
                        guard !next.isStopped else { return }
                        let request = try JSONDecoder().decode(IPCRequest.self, from: data)
                        let response = handler(request)
                        guard !next.isStopped else { return }
                        try IPCTransport.writeMessage(try JSONEncoder().encode(response), to: client, timeout: configuration.writeTimeout)
                    } catch {
                        // Do not reflect raw JSON, secrets, or unauthenticated errors.
                        // Closing also avoids sending any data to an untrusted peer.
                    }
                }
            }
        }
    }

    public func stop() {
        lifecycle.lock()
        let previous = context
        context = nil
        // Keep lifecycle serialized until the old accept generation releases its lock.
        previous?.stop()
        previous?.finished.wait()
        lifecycle.unlock()
    }
}

public final class IPCClient {
    private let configuration: IPCConfiguration
    private let trustedPeers: [URL]?
    public init(configuration: IPCConfiguration = IPCConfiguration(), trustedPeerExecutables: [URL]? = nil) {
        self.configuration = configuration
        self.trustedPeers = trustedPeerExecutables
    }

    public func send(_ request: IPCRequest) throws -> IPCResponse {
        try configuration.validate()
        let verifier = try IPCPeerVerifier(role: .client, trustedExecutables: trustedPeers)
        let directory = try IPCSecureDirectory(configuration.directoryURL, create: false)
        defer { Darwin.close(directory.fd) }
        try directory.validateSocket(requireExists: true)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw WhereKeyError.unavailable("无法创建本地连接") }
        defer { Darwin.close(fd) }
        try IPCTransport.configureDescriptor(fd)
        try IPCTransport.connect(fd, to: configuration.socketURL, timeout: configuration.requestTimeout)
        // Validate the live server before disclosing service names, paths, or keys.
        try verifier.verify(socket: fd)
        try IPCTransport.writeMessage(try JSONEncoder().encode(request), to: fd, timeout: configuration.writeTimeout)
        return try JSONDecoder().decode(IPCResponse.self, from: IPCTransport.readMessage(from: fd, timeout: configuration.responseTimeout))
    }
}
