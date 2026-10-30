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

public final class IPCServer: @unchecked Sendable {
    public typealias Handler = @Sendable (IPCRequest) -> IPCResponse

    private let handler: Handler
    private let queue = DispatchQueue(label: "com.wherekey.ipc", qos: .userInitiated, attributes: .concurrent)
    private var descriptor: Int32 = -1
    private var running = false

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    deinit { stop() }

    public func start() throws {
        guard !running else { return }
        try FileManager.default.createDirectory(at: IPCPath.directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: IPCPath.directory.path)
        unlink(IPCPath.socket.path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw WhereKeyError.unavailable("无法创建本地通信通道") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(IPCPath.socket.path.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd)
            throw WhereKeyError.unavailable("本地通信路径过长")
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { destination in
                for index in pathBytes.indices { destination[index] = pathBytes[index] }
            }
        }
        let addressLength = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, addressLength) }
        }
        guard bindResult == 0, Darwin.listen(fd, 16) == 0 else {
            Darwin.close(fd)
            throw WhereKeyError.unavailable("无法启动本地通信服务")
        }
        chmod(IPCPath.socket.path, 0o600)
        descriptor = fd
        running = true
        queue.async { [weak self] in self?.acceptLoop() }
    }

    public func stop() {
        running = false
        if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
        unlink(IPCPath.socket.path)
    }

    private func acceptLoop() {
        while running {
            let client = Darwin.accept(descriptor, nil, nil)
            guard client >= 0 else { if running { continue }; break }
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
                Darwin.close(client)
                continue
            }
            queue.async { [weak self] in self?.handle(client) }
        }
    }

    private func handle(_ client: Int32) {
        defer { Darwin.close(client) }
        do {
            let data = try Self.readMessage(from: client)
            let request = try JSONDecoder().decode(IPCRequest.self, from: data)
            let response = handler(request)
            try Self.writeMessage(try JSONEncoder().encode(response), to: client)
        } catch {
            let response = IPCResponse(ok: false, error: error.localizedDescription)
            if let data = try? JSONEncoder().encode(response) { try? Self.writeMessage(data, to: client) }
        }
    }

    fileprivate static func readMessage(from fd: Int32) throws -> Data {
        var lengthNetwork: UInt32 = 0
        try withUnsafeMutableBytes(of: &lengthNetwork) { buffer in
            try readExactly(fd, into: buffer)
        }
        let length = Int(UInt32(bigEndian: lengthNetwork))
        guard length > 0, length <= 1_048_576 else { throw WhereKeyError.unavailable("本地消息长度无效") }
        var data = Data(count: length)
        try data.withUnsafeMutableBytes { buffer in try readExactly(fd, into: buffer) }
        return data
    }

    fileprivate static func writeMessage(_ data: Data, to fd: Int32) throws {
        var length = UInt32(data.count).bigEndian
        try withUnsafeBytes(of: &length) { try writeAll(fd, from: $0) }
        try data.withUnsafeBytes { try writeAll(fd, from: $0) }
    }

    private static func readExactly(_ fd: Int32, into buffer: UnsafeMutableRawBufferPointer) throws {
        var offset = 0
        while offset < buffer.count {
            let count = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            guard count > 0 else { throw WhereKeyError.unavailable("本地连接已断开") }
            offset += count
        }
    }

    private static func writeAll(_ fd: Int32, from buffer: UnsafeRawBufferPointer) throws {
        var offset = 0
        while offset < buffer.count {
            let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            guard count > 0 else { throw WhereKeyError.unavailable("无法写入本地连接") }
            offset += count
        }
    }
}

public final class IPCClient {
    public init() {}

    public func send(_ request: IPCRequest) throws -> IPCResponse {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw WhereKeyError.ipcConnection("无法创建本地连接") }
        defer { Darwin.close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(IPCPath.socket.path.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw WhereKeyError.unavailable("本地通信路径过长")
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { destination in
                for index in pathBytes.indices { destination[index] = pathBytes[index] }
            }
        }
        let addressLength = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, addressLength) }
        }
        guard connected == 0 else { throw WhereKeyError.ipcConnection("WhereKey 应用未运行") }
        try IPCServer.writeMessage(try JSONEncoder().encode(request), to: fd)
        let response = try JSONDecoder().decode(IPCResponse.self, from: IPCServer.readMessage(from: fd))
        return response
    }
}
