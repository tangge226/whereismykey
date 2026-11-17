import Darwin
import Foundation
import Security

/// Pins the expected companion executable when the transport is created. An
/// identifier alone is insufficient for ad-hoc code: another process can reuse it.
final class IPCPeerVerifier {
    enum Role {
        case server
        case client

        fileprivate var ownIdentifier: String {
            self == .server ? "com.wherekey.mac" : "com.wherekey.cli"
        }
        fileprivate var peerIdentifier: String {
            self == .server ? "com.wherekey.cli" : "com.wherekey.mac"
        }
        fileprivate var ownName: String { self == .server ? "WhereKeyApp" : "wherekey" }
        fileprivate var peerName: String { self == .server ? "wherekey" : "WhereKeyApp" }
    }

    private struct TrustedExecutable {
        let url: URL
        let requirement: SecRequirement
    }

    private let trusted: [TrustedExecutable]
    private static let failureMessage = "WhereKey 本机通信身份校验失败，请使用同一版本的应用和 CLI。"
    private static let signatureFlags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)

    /// The explicit list is a dependency-injection seam for isolated fixtures.
    /// Production callers omit it; no environment variable can disable trust.
    init(role: Role, trustedExecutables: [URL]? = nil) throws {
        let (ownCode, ownStatic, ownInfo) = try Self.currentCode()
        let ownURL = try Self.executableURL(in: ownInfo)
        try Self.checkStatic(ownStatic)
        // Bind the disk signature used to find our layout to this running code.
        let selfRequirement = try Self.requirement(hashes: Self.hashes(in: ownInfo))
        guard SecCodeCheckValidity(ownCode, SecCSFlags(), selfRequirement) == errSecSuccess else {
            throw Self.failure()
        }

        let urls: [URL]
        let identifier: String?
        var enclosingBundle: SecStaticCode?
        if let trustedExecutables {
            guard !trustedExecutables.isEmpty else { throw Self.failure() }
            urls = trustedExecutables
            identifier = nil
        } else {
            guard ownInfo[kSecCodeInfoIdentifier as String] as? String == role.ownIdentifier,
                  ownURL.lastPathComponent == role.ownName else { throw Self.failure() }
            let location = try Self.companionLocation(ownURL: ownURL, role: role)
            urls = [location.peer]
            identifier = role.peerIdentifier
            if let bundle = location.bundle {
                let code = try Self.staticCode(at: bundle)
                try Self.checkStatic(code)
                enclosingBundle = code
            }
        }

        trusted = try urls.map { url in
            let canonical = Self.canonical(url)
            guard canonical.isFileURL, FileManager.default.isExecutableFile(atPath: canonical.path) else {
                throw Self.failure()
            }
            let code = try Self.staticCode(at: canonical)
            try Self.checkStatic(code)
            let info = try Self.signingInformation(code)
            if let identifier, info[kSecCodeInfoIdentifier as String] as? String != identifier {
                throw Self.failure()
            }
            var hashes = try Self.hashes(in: info)
            // CdHashes contains digest algorithms for one architecture, not all
            // fat slices. Include both supported product architectures explicitly.
            for architecture in ["arm64", "x86_64"] {
                var slice: SecStaticCode?
                let attributes = [kSecCodeAttributeArchitecture as String: architecture] as CFDictionary
                guard SecStaticCodeCreateWithPathAndAttributes(canonical as CFURL, SecCSFlags(), attributes, &slice) == errSecSuccess,
                      let slice else { continue }
                try Self.checkStatic(slice)
                hashes.append(contentsOf: try Self.hashes(in: Self.signingInformation(slice)))
            }
            return TrustedExecutable(url: canonical, requirement: try Self.requirement(hashes: hashes))
        }
        // Check the enclosing resource seal after examining the helper, too.
        if let enclosingBundle { try Self.checkStatic(enclosingBundle) }
        guard SecCodeCheckValidity(ownCode, SecCSFlags(), selfRequirement) == errSecSuccess else {
            throw Self.failure()
        }
    }

    func verify(socket: Int32) throws {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(socket, &uid, &gid) == 0, uid == getuid() else { throw Self.failure() }
        var token = audit_token_t()
        var size = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(socket, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0,
              size == MemoryLayout<audit_token_t>.size else { throw Self.failure() }
        let data = withUnsafeBytes(of: &token) { Data($0) }
        let attributes = [kSecGuestAttributeAudit as String: data] as CFDictionary
        var guest: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &guest) == errSecSuccess,
              let guest else { throw Self.failure() }
        for candidate in trusted {
            // A kernel audit token includes the PID version. Never downgrade to
            // PID-only lookup, which can race process exit and PID reuse.
            guard SecCodeCheckValidity(guest, SecCSFlags(), candidate.requirement) == errSecSuccess else { continue }
            var diskCode: SecStaticCode?
            guard SecCodeCopyStaticCode(guest, SecCSFlags(), &diskCode) == errSecSuccess,
                  let diskCode,
                  let info = try? Self.signingInformation(diskCode),
                  let peerURL = try? Self.executableURL(in: info),
                  peerURL == candidate.url else { continue }
            return
        }
        throw Self.failure()
    }

    static func currentExecutableURL() throws -> URL {
        let (_, _, info) = try currentCode()
        return try executableURL(in: info)
    }

    private static func currentCode() throws -> (SecCode, SecStaticCode, [String: Any]) {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, SecCSFlags(), nil) == errSecSuccess else { throw failure() }
        var disk: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &disk) == errSecSuccess, let disk else { throw failure() }
        return (code, disk, try signingInformation(disk))
    }

    private static func companionLocation(ownURL: URL, role: Role) throws -> (peer: URL, bundle: URL?) {
        let directory = ownURL.deletingLastPathComponent()
        let contents = directory.deletingLastPathComponent()
        let bundle = contents.deletingLastPathComponent()
        if contents.lastPathComponent == "Contents", bundle.pathExtension.lowercased() == "app" {
            let ownDirectory = role == .server ? "MacOS" : "Helpers"
            let peerDirectory = role == .server ? "Helpers" : "MacOS"
            guard directory.lastPathComponent == ownDirectory else { throw failure() }
            return (contents.appendingPathComponent(peerDirectory).appendingPathComponent(role.peerName), bundle)
        }
        // The build scripts sign both neighboring development executables.
        return (directory.appendingPathComponent(role.peerName), nil)
    }

    private static func staticCode(at url: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code) == errSecSuccess, let code else { throw failure() }
        return code
    }

    private static func checkStatic(_ code: SecStaticCode) throws {
        guard SecStaticCodeCheckValidity(code, signatureFlags, nil) == errSecSuccess else { throw failure() }
    }

    private static func signingInformation(_ code: SecStaticCode) throws -> [String: Any] {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(), &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { throw failure() }
        return dictionary
    }

    private static func executableURL(in information: [String: Any]) throws -> URL {
        guard let url = information[kSecCodeInfoMainExecutable as String] as? URL, url.isFileURL else { throw failure() }
        return canonical(url)
    }

    private static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func hashes(in information: [String: Any]) throws -> [Data] {
        let hashes = information[kSecCodeInfoCdHashes as String] as? [Data]
            ?? (information[kSecCodeInfoUnique as String] as? Data).map { [$0] }
            ?? []
        guard !hashes.isEmpty, hashes.allSatisfy({ !$0.isEmpty }) else { throw failure() }
        return hashes
    }

    private static func requirement(hashes: [Data]) throws -> SecRequirement {
        let expressions = Set(hashes.map { hash in
            "cdhash H\"" + hash.map { String(format: "%02x", $0) }.joined() + "\""
        }).sorted()
        guard !expressions.isEmpty else { throw failure() }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(expressions.map { "(\($0))" }.joined(separator: " or ") as CFString,
                                             SecCSFlags(), &requirement) == errSecSuccess,
              let requirement else { throw failure() }
        return requirement
    }

    private static func failure() -> WhereKeyError { .ipcAuthentication(failureMessage) }
}
