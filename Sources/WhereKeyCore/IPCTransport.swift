import Darwin
import Foundation

internal enum IPCTransport {
    static let maximumMessageSize = 1_048_576

    static func configureDescriptor(_ fd: Int32) throws {
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else {
            throw WhereKeyError.unavailable("无法保护本地连接")
        }
        var enabled: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0 else {
            throw WhereKeyError.unavailable("无法保护本地连接")
        }
    }

    static func address(_ url: URL) throws -> sockaddr_un {
        let path = Array(url.path.utf8CString)
        var address = sockaddr_un()
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw WhereKeyError.unavailable("本地通信路径过长") }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &address.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: path.count) { dest in
                for index in path.indices { dest[index] = path[index] }
            }
        }
        return address
    }

    static func connect(_ fd: Int32, to url: URL, timeout: TimeInterval) throws {
        var addr = try address(url)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        var error = errno
        if result == 0 { return }
        if [EINPROGRESS, EAGAIN, EWOULDBLOCK].contains(error) {
            try wait(fd, event: POLLOUT, deadline: ProcessInfo.processInfo.systemUptime + timeout)
            var size = socklen_t(MemoryLayout.size(ofValue: error))
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0 else { throw WhereKeyError.unavailable("无法连接本地服务") }
            if error == 0 { return }
        }
        if error == ENOENT || error == ECONNREFUSED { throw WhereKeyError.ipcConnection("WhereKey 应用未运行") }
        throw WhereKeyError.unavailable("无法连接本地服务")
    }

    static func wait(_ fd: Int32, event: Int32, deadline: TimeInterval) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw WhereKeyError.unavailable("本地连接超时") }
            var descriptor = pollfd(fd: fd, events: Int16(event), revents: 0)
            let ready = Darwin.poll(&descriptor, 1, Int32(min(remaining * 1000 + 1, Double(Int32.max))))
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0 else { throw WhereKeyError.unavailable("本地连接超时或已断开") }
            guard descriptor.revents & Int16(POLLNVAL | POLLERR) == 0 else { throw WhereKeyError.unavailable("本地连接已断开") }
            return
        }
    }

    static func readMessage(from fd: Int32, timeout: TimeInterval = 5) throws -> Data {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var length: UInt32 = 0
        try withUnsafeMutableBytes(of: &length) { try read(fd, into: $0, deadline: deadline) }
        let count = Int(UInt32(bigEndian: length))
        guard count > 0 && count <= maximumMessageSize else { throw WhereKeyError.unavailable("本地消息长度无效") }
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { try read(fd, into: $0, deadline: deadline) }
        return data
    }

    static func writeMessage(_ data: Data, to fd: Int32, timeout: TimeInterval = 5) throws {
        guard !data.isEmpty && data.count <= maximumMessageSize else { throw WhereKeyError.unavailable("本地消息长度无效") }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var size = UInt32(data.count).bigEndian
        try withUnsafeBytes(of: &size) { try write(fd, from: $0, deadline: deadline) }
        try data.withUnsafeBytes { try write(fd, from: $0, deadline: deadline) }
    }

    private static func read(_ fd: Int32, into buffer: UnsafeMutableRawBufferPointer, deadline: TimeInterval) throws {
        var offset = 0
        while offset < buffer.count {
            try wait(fd, event: POLLIN, deadline: deadline)
            let count = Darwin.recv(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
            if count < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
            guard count > 0 else { throw WhereKeyError.unavailable("本地连接已断开") }
            offset += count
        }
    }

    private static func write(_ fd: Int32, from buffer: UnsafeRawBufferPointer, deadline: TimeInterval) throws {
        var offset = 0
        while offset < buffer.count {
            try wait(fd, event: POLLOUT, deadline: deadline)
            let count = Darwin.send(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
            if count < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
            guard count > 0 else { throw WhereKeyError.unavailable("无法写入本地连接") }
            offset += count
        }
    }
}

internal struct IPCSecureDirectory {
    let fd: Int32
    let url: URL
    let identity: stat
    static let socketName = "wherekey.sock"

    init(_ url: URL, create: Bool) throws {
        self.url = url.standardizedFileURL
        if create && mkdir(self.url.path, 0o700) != 0 && errno != EEXIST { throw WhereKeyError.unavailable("无法创建私有通信目录") }
        let descriptor = Darwin.open(self.url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { throw WhereKeyError.ipcConnection("WhereKey 应用未运行") }
            throw WhereKeyError.ipcAuthentication("通信目录不安全，已拒绝连接")
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o777 == 0o700 else {
            Darwin.close(descriptor)
            throw WhereKeyError.ipcAuthentication("通信目录必须由当前用户独占访问")
        }
        self.fd = descriptor
        self.identity = info
    }

    func entry() throws -> stat? {
        var info = stat()
        if fstatat(fd, Self.socketName, &info, AT_SYMLINK_NOFOLLOW) == 0 { return info }
        if errno == ENOENT { return nil }
        throw WhereKeyError.ipcAuthentication("无法确认通信端点身份")
    }

    func validateSocket(requireExists: Bool) throws {
        guard let info = try entry() else {
            if requireExists { throw WhereKeyError.ipcConnection("WhereKey 应用未运行") }
            return
        }
        guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK, info.st_mode & 0o777 == 0o600 else {
            throw WhereKeyError.ipcAuthentication("通信端点类型或权限不安全")
        }
    }

    func pathStillMatches() -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_dev == identity.st_dev && info.st_ino == identity.st_ino
    }
}

internal final class IPCServerContext: @unchecked Sendable {
    let listener: Int32
    let finished = DispatchGroup()
    private let directory: IPCSecureDirectory
    private let lockFD: Int32
    private let ownedSocket: stat
    private let state = NSLock()
    private var stopped = false
    private var connections = Set<Int32>()
    private let maximumConnections: Int
    var isStopped: Bool { state.lock(); defer { state.unlock() }; return stopped }

    init(configuration: IPCConfiguration) throws {
        let directory = try IPCSecureDirectory(configuration.directoryURL, create: true)
        let lockFD = openat(directory.fd, ".instance.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { Darwin.close(directory.fd); throw WhereKeyError.ipcAuthentication("通信实例锁不安全") }
        var lockInfo = stat()
        guard fstat(lockFD, &lockInfo) == 0, lockInfo.st_uid == getuid(), lockInfo.st_mode & S_IFMT == S_IFREG,
              lockInfo.st_nlink == 1, lockInfo.st_mode & 0o777 == 0o600,
              flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(lockFD); Darwin.close(directory.fd)
            throw WhereKeyError.unavailable("已有 WhereKey 实例运行，或通信实例锁不安全")
        }
        var newListener: Int32 = -1
        var created: stat?
        do {
            try directory.validateSocket(requireExists: false)
            if let old = try directory.entry() {
                let probe = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
                guard probe >= 0 else { throw WhereKeyError.unavailable("无法检查旧通信端点") }
                defer { Darwin.close(probe) }
                try IPCTransport.configureDescriptor(probe)
                do {
                    try IPCTransport.connect(probe, to: configuration.socketURL, timeout: 0.2)
                    throw WhereKeyError.unavailable("通信端点已被使用")
                } catch WhereKeyError.ipcConnection {
                    guard let unchanged = try directory.entry(), unchanged.st_dev == old.st_dev && unchanged.st_ino == old.st_ino,
                          unlinkat(directory.fd, IPCSecureDirectory.socketName, 0) == 0 else { throw WhereKeyError.ipcAuthentication("旧端点身份已改变") }
                }
            }
            guard directory.pathStillMatches() else { throw WhereKeyError.ipcAuthentication("通信目录身份已改变") }
            newListener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard newListener >= 0 else { throw WhereKeyError.unavailable("无法创建本地通信通道") }
            try IPCTransport.configureDescriptor(newListener)
            var address = try IPCTransport.address(configuration.socketURL)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(newListener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard bound == 0, let socketInfo = try directory.entry(), socketInfo.st_mode & S_IFMT == S_IFSOCK,
                  socketInfo.st_uid == getuid() else { throw WhereKeyError.unavailable("无法绑定本地通信端点") }
            created = socketInfo
            guard directory.pathStillMatches(), fchmodat(directory.fd, IPCSecureDirectory.socketName, 0o600, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw WhereKeyError.ipcAuthentication("无法保护通信端点权限")
            }
            try directory.validateSocket(requireExists: true)
            guard Darwin.listen(newListener, Int32(configuration.maxConnections)) == 0 else { throw WhereKeyError.unavailable("无法监听本地通信端点") }
            self.listener = newListener
            self.directory = directory
            self.lockFD = lockFD
            self.ownedSocket = socketInfo
            self.maximumConnections = configuration.maxConnections
            finished.enter()
        } catch {
            if newListener >= 0 { Darwin.close(newListener) }
            if let created, let current = try? directory.entry(), current.st_dev == created.st_dev && current.st_ino == created.st_ino {
                unlinkat(directory.fd, IPCSecureDirectory.socketName, 0)
            }
            Darwin.close(lockFD); Darwin.close(directory.fd)
            throw error
        }
    }

    func register(_ fd: Int32) -> Bool {
        state.lock(); defer { state.unlock() }
        guard !stopped && connections.count < maximumConnections else { return false }
        connections.insert(fd)
        return true
    }

    func release(_ fd: Int32) {
        state.lock()
        // Close while locked so stop cannot shutdown an already-reused FD.
        connections.remove(fd)
        Darwin.close(fd)
        state.unlock()
    }

    func stop() {
        state.lock()
        stopped = true
        for fd in connections { Darwin.shutdown(fd, SHUT_RDWR) }
        state.unlock()
    }

    func finish() {
        Darwin.close(listener)
        if let current = try? directory.entry(), current.st_dev == ownedSocket.st_dev && current.st_ino == ownedSocket.st_ino {
            unlinkat(directory.fd, IPCSecureDirectory.socketName, 0)
        }
        Darwin.close(lockFD)
        Darwin.close(directory.fd)
        finished.leave()
    }
}
