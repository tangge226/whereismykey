import Darwin
import Foundation
import Security
import XCTest
@testable import WhereKeyCore

/// All endpoints, messages, and process identities in this suite are isolated
/// fixtures. No test opens the user's normal socket, metadata, or Keychain.
final class IPCTransportTests: XCTestCase {
    private var directory: URL!
    private var trustedExecutable: URL!

    override func setUpWithError() throws {
        // Keep sockaddr_un paths short and avoid /tmp's symlink on macOS.
        directory = URL(fileURLWithPath: "/private/tmp/wki-" + UUID().uuidString.prefix(10), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        trustedExecutable = try currentExecutable()
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testDescriptorDisablesInheritanceBlockingAndSIGPIPE() throws {
        let pair = try socketPair()
        defer { closePair(pair) }
        XCTAssertNotEqual(fcntl(pair.0, F_GETFD) & FD_CLOEXEC, 0)
        XCTAssertNotEqual(fcntl(pair.0, F_GETFL) & O_NONBLOCK, 0)
        var value: Int32 = 0
        var length = socklen_t(MemoryLayout.size(ofValue: value))
        XCTAssertEqual(getsockopt(pair.0, SOL_SOCKET, SO_NOSIGPIPE, &value, &length), 0)
        XCTAssertEqual(value, 1)
    }

    func testReceiveRejectsZeroAndOversizedFrameLengths() throws {
        for length: UInt32 in [0, 1_048_577, UInt32.max] {
            let pair = try socketPair()
            defer { closePair(pair) }
            try writeRaw(pair.1, header(length))
            let start = Date()
            XCTAssertThrowsError(try IPCTransport.readMessage(from: pair.0, timeout: 0.15))
            XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        }
    }

    func testSendRejectsEmptyAndOversizedFramesBeforeWriting() throws {
        for data in [Data(), Data(repeating: 0x61, count: 1_048_577)] {
            let pair = try socketPair()
            defer { closePair(pair) }
            XCTAssertThrowsError(try IPCTransport.writeMessage(data, to: pair.0, timeout: 0.15))
            var byte: UInt8 = 0
            let received = Darwin.read(pair.1, &byte, 1)
            let readError = errno
            XCTAssertEqual(received, -1, "Rejected frames must not emit a header")
            XCTAssertTrue(readError == EAGAIN || readError == EWOULDBLOCK)
        }
    }

    func testTruncatedHeaderAndBodyAreRejected() throws {
        for partial in [Data([0, 0]), header(8) + Data([1, 2])] {
            let pair = try socketPair()
            defer { closePair(pair) }
            try writeRaw(pair.1, partial)
            XCTAssertEqual(Darwin.shutdown(pair.1, SHUT_WR), 0)
            XCTAssertThrowsError(try IPCTransport.readMessage(from: pair.0, timeout: 0.15))
        }
    }

    func testFragmentedFrameIsReadWithoutLosingBytes() throws {
        let pair = try socketPair()
        defer { closePair(pair) }
        let payload = Data("synthetic IPC payload".utf8)
        let frame = header(UInt32(payload.count)) + payload
        let finished = expectation(description: "fragmented writer")
        let failure = LockedValue<Error?>(nil)
        DispatchQueue.global().async {
            defer { finished.fulfill() }
            do {
                for byte in frame {
                    try self.writeRaw(pair.1, Data([byte]))
                    Thread.sleep(forTimeInterval: 0.001)
                }
            } catch { failure.set(error) }
        }
        XCTAssertEqual(try IPCTransport.readMessage(from: pair.0, timeout: 1), payload)
        wait(for: [finished], timeout: 2)
        XCTAssertNil(failure.get())
    }

    func testSlowProgressCannotExtendWholeFrameDeadline() throws {
        let pair = try socketPair()
        defer { closePair(pair) }
        let frame = header(100) + Data(repeating: 0x61, count: 31)
        let finished = expectation(description: "slow fixture writer")
        DispatchQueue.global().async {
            defer { finished.fulfill() }
            for byte in frame {
                // Each byte arrives faster than the read timeout. A per-read
                // timeout would keep the connection alive beyond 0.5 seconds.
                try? self.writeRaw(pair.1, Data([byte]))
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        let start = Date()
        XCTAssertThrowsError(try IPCTransport.readMessage(from: pair.0, timeout: 0.15))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        wait(for: [finished], timeout: 3)
    }

    func testIdleReadAndBackpressuredWriteHaveDeadlines() throws {
        let pair = try socketPair()
        defer { closePair(pair) }
        let readStart = Date()
        XCTAssertThrowsError(try IPCTransport.readMessage(from: pair.0, timeout: 0.15))
        XCTAssertLessThan(Date().timeIntervalSince(readStart), 1)
        var sendBuffer: Int32 = 4_096
        XCTAssertEqual(setsockopt(pair.0, SOL_SOCKET, SO_SNDBUF, &sendBuffer,
                                 socklen_t(MemoryLayout.size(ofValue: sendBuffer))), 0)
        let writeStart = Date()
        XCTAssertThrowsError(try IPCTransport.writeMessage(Data(repeating: 0x61, count: 1_048_576), to: pair.0, timeout: 0.15))
        XCTAssertLessThan(Date().timeIntervalSince(writeStart), 1)
    }

    func testDisconnectedPeerDoesNotKillWriterWithSIGPIPE() throws {
        let pair = try socketPair()
        defer { closePair(pair) }
        XCTAssertEqual(Darwin.shutdown(pair.1, SHUT_RDWR), 0)
        XCTAssertThrowsError(try IPCTransport.writeMessage(Data([0x61]), to: pair.0, timeout: 0.15))
    }

    func testDirectorySymlinkIsRejectedWithoutChmodOfTarget() throws {
        let target = directory.appendingPathComponent("target", isDirectory: true)
        let link = directory.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o755])
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        do {
            let server = makeServer(directory: link)
            XCTAssertThrowsError(try server.start())
        }
        XCTAssertEqual(try permissions(target), 0o755)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
    }

    func testRegularFileAndSymlinkEndpointsAreNotRemoved() throws {
        let endpoint = socketPath()
        let data = Data("synthetic non-socket fixture".utf8)
        try data.write(to: endpoint)
        do {
            let server = makeServer()
            XCTAssertThrowsError(try server.start())
        }
        XCTAssertEqual(try Data(contentsOf: endpoint), data)
        try FileManager.default.removeItem(at: endpoint)

        let target = directory.appendingPathComponent("fixture-target")
        try data.write(to: target)
        try FileManager.default.createSymbolicLink(at: endpoint, withDestinationURL: target)
        do {
            let server = makeServer()
            XCTAssertThrowsError(try server.start())
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: endpoint.path), target.path)
        XCTAssertEqual(try Data(contentsOf: target), data)
    }

    func testSecondInstanceAndFailedDeinitCannotTakeOverActiveSocket() throws {
        let first = makeServer()
        defer { first.stop() }
        try first.start()
        let originalInode = try inode(socketPath())
        do {
            let second = makeServer()
            XCTAssertThrowsError(try second.start())
            second.stop()
        }
        // A separate never-started object's teardown also has no ownership.
        do { let unused = makeServer(); unused.stop() }
        XCTAssertEqual(try inode(socketPath()), originalInode)
        XCTAssertTrue(try makeClient().send(IPCRequest(action: "catalog")).ok)
    }

    func testStopDoesNotUnlinkAReplacementSocket() throws {
        let server = makeServer()
        try server.start()
        defer { server.stop() }
        let path = socketPath()
        XCTAssertEqual(unlink(path.path), 0)
        let replacement = try boundSocket(path)
        defer { Darwin.close(replacement) }
        let replacementInode = try inode(path)
        server.stop()
        XCTAssertEqual(try inode(path), replacementInode)
        let connected = try rawConnect(path)
        Darwin.close(connected)
    }

    func testClientRejectsSymlinkEndpointAndPreservesDirectoryPermissions() throws {
        let target = directory.appendingPathComponent("real-socket")
        let endpoint = socketPath()
        let listener = try boundSocket(target)
        defer { Darwin.close(listener) }
        try FileManager.default.createSymbolicLink(at: endpoint, withDestinationURL: target)
        XCTAssertThrowsError(try makeClient().send(IPCRequest(action: "catalog")))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: endpoint.path), target.path)
        XCTAssertEqual(try permissions(directory), 0o700)
    }

    func testConnectionLimitDoesNotRunAdditionalHandler() throws {
        let started = expectation(description: "first handler occupies one slot")
        let release = DispatchSemaphore(value: 0)
        let calls = LockedValue(0)
        let configuration = configuration(maxConnections: 1, responseTimeout: 0.4)
        let server = IPCServer(configuration: configuration, trustedPeerExecutables: [trustedExecutable]) { _ in
            calls.update { $0 += 1 }
            started.fulfill()
            _ = release.wait(timeout: .now() + 4)
            return IPCResponse(ok: true)
        }
        try server.start()
        defer { release.signal(); server.stop() }
        let first = try rawConnect(socketPath())
        defer { Darwin.close(first) }
        try IPCTransport.writeMessage(try JSONEncoder().encode(IPCRequest(action: "catalog")), to: first, timeout: 1)
        wait(for: [started], timeout: 2)
        let client = IPCClient(configuration: configuration, trustedPeerExecutables: [trustedExecutable])
        XCTAssertThrowsError(try client.send(IPCRequest(action: "catalog")))
        XCTAssertEqual(calls.get(), 1)
        release.signal()
        let data = try IPCTransport.readMessage(from: first, timeout: 2)
        XCTAssertTrue(try JSONDecoder().decode(IPCResponse.self, from: data).ok)
    }

    func testConcurrentStopsAreIdempotentAndAllowRestart() throws {
        let server = makeServer()
        try server.start()
        defer { server.stop() }
        let completed = expectation(description: "concurrent stops")
        completed.expectedFulfillmentCount = 4
        for _ in 0..<4 {
            DispatchQueue.global().async { server.stop(); completed.fulfill() }
        }
        wait(for: [completed], timeout: 3)
        try server.start()
        XCTAssertTrue(try makeClient().send(IPCRequest(action: "catalog")).ok)
    }

    func testRepeatedStartStopDoesNotKeepAStaleListener() throws {
        let server = makeServer()
        defer { server.stop() }
        for _ in 0..<5 {
            try server.start()
            XCTAssertTrue(try makeClient().send(IPCRequest(action: "catalog")).ok)
            server.stop()
            XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath().path))
        }
    }

    private func configuration(directory override: URL? = nil, maxConnections: Int = 8,
                               responseTimeout: TimeInterval = 3) -> IPCConfiguration {
        IPCConfiguration(directoryURL: override ?? directory, requestTimeout: 1,
                         responseTimeout: responseTimeout, writeTimeout: 1, maxConnections: maxConnections)
    }

    private func makeServer(directory override: URL? = nil) -> IPCServer {
        IPCServer(configuration: configuration(directory: override), trustedPeerExecutables: [trustedExecutable]) { _ in
            IPCResponse(ok: true)
        }
    }

    private func makeClient() -> IPCClient {
        IPCClient(configuration: configuration(), trustedPeerExecutables: [trustedExecutable])
    }

    private func socketPath() -> URL { directory.appendingPathComponent("wherekey.sock") }

    private func currentExecutable() throws -> URL {
        var code: SecCode?
        try requireSuccess(SecCodeCopySelf([], &code))
        var staticCode: SecStaticCode?
        try requireSuccess(SecCodeCopyStaticCode(try XCTUnwrap(code), [], &staticCode))
        var information: CFDictionary?
        try requireSuccess(SecCodeCopySigningInformation(try XCTUnwrap(staticCode), SecCSFlags(rawValue: kSecCSSigningInformation), &information))
        let values = try XCTUnwrap(information as? [String: Any])
        return try XCTUnwrap(values[kSecCodeInfoMainExecutable as String] as? URL)
    }

    private func requireSuccess(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    private func permissions(_ path: URL) throws -> Int {
        let value = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber
        return try XCTUnwrap(value).intValue
    }

    private func inode(_ path: URL) throws -> UInt64 {
        let value = try FileManager.default.attributesOfItem(atPath: path.path)[.systemFileNumber] as? NSNumber
        return try XCTUnwrap(value).uint64Value
    }

    private func socketPair() throws -> (Int32, Int32) {
        var descriptors: [Int32] = [-1, -1]
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else { throw posixError() }
        do {
            try IPCTransport.configureDescriptor(descriptors[0])
            try IPCTransport.configureDescriptor(descriptors[1])
        } catch {
            descriptors.forEach { Darwin.close($0) }
            throw error
        }
        return (descriptors[0], descriptors[1])
    }

    private func closePair(_ pair: (Int32, Int32)) {
        Darwin.close(pair.0)
        Darwin.close(pair.1)
    }

    private func header(_ length: UInt32) -> Data {
        var value = length.bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    private func writeRaw(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count; continue }
                if count < 0 && errno == EINTR { continue }
                if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    var item = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    guard Darwin.poll(&item, 1, 1_000) > 0 else { throw posixError() }
                    continue
                }
                throw posixError()
            }
        }
    }

    private func rawConnect(_ path: URL) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw posixError() }
        do {
            try withAddress(path) { pointer, length in
                guard Darwin.connect(fd, pointer, length) == 0 else { throw posixError() }
            }
            try IPCTransport.configureDescriptor(fd)
            return fd
        } catch { Darwin.close(fd); throw error }
    }

    private func boundSocket(_ path: URL) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw posixError() }
        do {
            try IPCTransport.configureDescriptor(fd)
            try withAddress(path) { pointer, length in
                guard Darwin.bind(fd, pointer, length) == 0 else { throw posixError() }
            }
            guard chmod(path.path, 0o600) == 0, Darwin.listen(fd, 4) == 0 else { throw posixError() }
            return fd
        } catch { Darwin.close(fd); throw error }
    }

    private func withAddress<T>(_ path: URL, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENAMETOOLONG)) }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count)
        address.sun_len = UInt8(length)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: bytes.count) { target in
                for index in bytes.indices { target[index] = bytes[index] }
            }
        }
        return try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, length) }
        }
    }

    private func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: Value) { lock.lock(); defer { lock.unlock() }; self.value = value }
    func update(_ body: (inout Value) -> Void) { lock.lock(); defer { lock.unlock() }; body(&value) }
}
