import Darwin
import Foundation
import XCTest
@testable import WhereKeyCore

final class IPCPeerTrustTests: XCTestCase {
    func testAuditTokenAcceptsOnlyExplicitlyPinnedCurrentExecutable() throws {
        let executable = try IPCPeerVerifier.currentExecutableURL()
        let verifier = try IPCPeerVerifier(role: .server, trustedExecutables: [executable])
        var sockets = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer { sockets.forEach { close($0) } }
        XCTAssertNoThrow(try verifier.verify(socket: sockets[0]))
    }

    func testDifferentSignedExecutableCannotMatchPeer() throws {
        let verifier = try IPCPeerVerifier(role: .client, trustedExecutables: [URL(fileURLWithPath: "/bin/echo")])
        var sockets = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer { sockets.forEach { close($0) } }
        XCTAssertThrowsError(try verifier.verify(socket: sockets[0])) { error in
            guard case WhereKeyError.ipcAuthentication = error else { return XCTFail("Expected authentication failure") }
        }
    }

    func testEmptyTrustListAndInvalidDescriptorFailClosed() throws {
        XCTAssertThrowsError(try IPCPeerVerifier(role: .client, trustedExecutables: []))
        let verifier = try IPCPeerVerifier(role: .server, trustedExecutables: [IPCPeerVerifier.currentExecutableURL()])
        XCTAssertThrowsError(try verifier.verify(socket: -1))
    }

    func testUnsignedFixtureCannotBecomeTrustedPeer() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WhereKey-Unsigned-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("peer")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        XCTAssertThrowsError(try IPCPeerVerifier(role: .client, trustedExecutables: [executable]))
    }
}
