import Foundation
import LocalAuthentication
import Security
import XCTest
@testable import WhereKeyCore

final class KeychainStoreTests: XCTestCase {
    private final class Fixture {
        var allowed = true
        var setters: [Bool] = []
        var getStatus: OSStatus = errSecSuccess
        var setterStatuses: [OSStatus] = []
        var reads: [[String: Any]] = []
        var updates: [([String: Any], [String: Any])] = []
        var adds: [[String: Any]] = []
        var deletes: [[String: Any]] = []
        var readStatus: OSStatus = errSecSuccess
        var readData: Data? = Data("synthetic-key-value".utf8)
        var updateStatus: OSStatus = errSecSuccess
        var addStatus: OSStatus = errSecSuccess
        var deleteStatus: OSStatus = errSecSuccess
        var policyViolation = false
        var authenticationUIForbidden: [Bool] = []

        func store() -> KeychainStore {
            KeychainStore(operations: KeychainOperations(read: { query in
                self.checkPolicy(query)
                self.reads.append(query)
                return (self.readStatus, self.readData)
            }, update: { query, value in
                self.checkPolicy(query)
                self.updates.append((query, value))
                return self.updateStatus
            }, add: { query in
                self.checkPolicy(query)
                self.adds.append(query)
                return self.addStatus
            }, delete: { query in
                self.checkPolicy(query)
                self.deletes.append(query)
                return self.deleteStatus
            }), interaction: KeychainInteractionOperations(getAllowed: {
                (self.getStatus, self.allowed)
            }, setAllowed: { requested in
                self.setters.append(requested)
                let status = self.setterStatuses.isEmpty ? errSecSuccess : self.setterStatuses.removeFirst()
                if status == errSecSuccess { self.allowed = requested }
                return status
            }))
        }

        func checkPolicy(_ query: [String: Any]) {
            guard let context = query[kSecUseAuthenticationContext as String] as? LAContext else {
                policyViolation = true
                return
            }
            authenticationUIForbidden.append(context.interactionNotAllowed)
            if context.interactionNotAllowed == allowed { policyViolation = true }
        }
    }

    private func assertScope(_ query: [String: Any], account: String = "synthetic-account", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String, file: file, line: line)
        XCTAssertEqual(query[kSecAttrService as String] as? String, KeychainStore.serviceName, file: file, line: line)
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, account, file: file, line: line)
        XCTAssertNil(query[kSecUseDataProtectionKeychain as String], file: file, line: line)
        XCTAssertNil(query[kSecAttrAccess as String], file: file, line: line)
        XCTAssertNil(query[kSecAttrAccessControl as String], file: file, line: line)
    }

    func testQuietReadHasOneExactQueryAndRestoresPolicy() throws {
        let fixture = Fixture()
        XCTAssertEqual(try fixture.store().read(account: "synthetic-account"), "synthetic-key-value")
        XCTAssertEqual(fixture.reads.count, 1)
        let query = try XCTUnwrap(fixture.reads.first)
        assertScope(query)
        XCTAssertEqual(query[kSecReturnData as String] as? Bool, true)
        XCTAssertEqual(query[kSecMatchLimit as String] as? String, kSecMatchLimitOne as String)
        XCTAssertEqual(fixture.authenticationUIForbidden, [true])
        XCTAssertEqual(fixture.setters, [false, true])
        XCTAssertTrue(fixture.allowed)
        XCTAssertFalse(fixture.policyViolation)
    }

    func testInteractiveReadIsExplicitAndUsesANewContextEachTime() throws {
        let fixture = Fixture()
        fixture.allowed = false
        let store = fixture.store()
        _ = try store.read(account: "synthetic-account", interactive: true)
        _ = try store.read(account: "synthetic-account", interactive: true)
        let contexts = fixture.reads.compactMap { $0[kSecUseAuthenticationContext as String] as? LAContext }
        XCTAssertEqual(contexts.count, 2)
        XCTAssertNotEqual(ObjectIdentifier(contexts[0]), ObjectIdentifier(contexts[1]))
        XCTAssertEqual(fixture.authenticationUIForbidden, [false, false])
        XCTAssertEqual(fixture.setters, [true, false, true, false])
        XCTAssertFalse(fixture.allowed)
        XCTAssertFalse(fixture.policyViolation)
    }

    func testDeniedOrCanceledReadDoesNotRetryAndRestoresPolicy() {
        for status in [errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled] {
            let fixture = Fixture()
            fixture.readStatus = status
            XCTAssertThrowsError(try fixture.store().read(account: "synthetic-account", interactive: status == errSecUserCanceled)) {
                XCTAssertEqual($0 as? WhereKeyError, .authorizationRequired("synthetic-account"))
            }
            XCTAssertEqual(fixture.reads.count, 1)
            XCTAssertEqual(fixture.setters.count, 2)
            XCTAssertTrue(fixture.allowed)
        }
    }

    func testMissingAndMalformedReadNeverReturnsPartialData() {
        let missing = Fixture()
        missing.readStatus = errSecItemNotFound
        XCTAssertThrowsError(try missing.store().read(account: "synthetic-account")) {
            XCTAssertEqual($0 as? WhereKeyError, .notFound("秘密值不存在"))
        }
        for data: Data? in [nil, Data([0xFF])] {
            let fixture = Fixture()
            fixture.readData = data
            XCTAssertThrowsError(try fixture.store().read(account: "synthetic-account")) {
                XCTAssertEqual($0 as? WhereKeyError, .storage("Keychain 数据格式无效"))
            }
            XCTAssertTrue(fixture.allowed)
        }
    }

    func testExistingSaveIsQuietAndNeverDeletesOrAdds() throws {
        let fixture = Fixture()
        try fixture.store().save("synthetic-replacement", account: "synthetic-account")
        XCTAssertEqual(fixture.updates.count, 1)
        let (query, updates) = try XCTUnwrap(fixture.updates.first)
        assertScope(query)
        XCTAssertEqual(updates.keys.sorted(), [kSecValueData as String])
        XCTAssertEqual(updates[kSecValueData as String] as? Data, Data("synthetic-replacement".utf8))
        XCTAssertTrue(fixture.adds.isEmpty)
        XCTAssertTrue(fixture.deletes.isEmpty)
        XCTAssertEqual(fixture.setters, [false, true])
        XCTAssertFalse(fixture.policyViolation)
    }

    func testNewSaveOnlyAddsOnNotFoundAndRemainsLocal() throws {
        let fixture = Fixture()
        fixture.updateStatus = errSecItemNotFound
        try fixture.store().save("synthetic-new-value", account: "synthetic-account")
        XCTAssertEqual(fixture.updates.count, 1)
        XCTAssertEqual(fixture.adds.count, 1)
        let query = try XCTUnwrap(fixture.adds.first)
        assertScope(query)
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(query[kSecValueData as String] as? Data, Data("synthetic-new-value".utf8))
        XCTAssertFalse(fixture.policyViolation)
        XCTAssertTrue(fixture.allowed)
    }

    func testSaveFailureDoesNotRetryOrReplaceAnExistingItem() {
        for status in [errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled, errSecParam] {
            let fixture = Fixture()
            fixture.updateStatus = status
            XCTAssertThrowsError(try fixture.store().save("synthetic-new-value", account: "synthetic-account"))
            XCTAssertEqual(fixture.updates.count, 1)
            XCTAssertTrue(fixture.adds.isEmpty)
            XCTAssertTrue(fixture.deletes.isEmpty)
            XCTAssertTrue(fixture.allowed)
        }
        let fixture = Fixture()
        fixture.updateStatus = errSecItemNotFound
        fixture.addStatus = errSecDuplicateItem
        XCTAssertThrowsError(try fixture.store().save("synthetic-new-value", account: "synthetic-account")) {
            XCTAssertEqual($0 as? WhereKeyError, .keychain(errSecDuplicateItem))
        }
        XCTAssertEqual(fixture.updates.count, 1)
        XCTAssertEqual(fixture.adds.count, 1)
        XCTAssertTrue(fixture.deletes.isEmpty)
    }

    func testDeleteIsQuietExactAndIdempotentWithoutRewritingACLs() throws {
        for status in [errSecSuccess, errSecItemNotFound] {
            let fixture = Fixture()
            fixture.deleteStatus = status
            try fixture.store().delete(account: "synthetic-account")
            XCTAssertEqual(fixture.deletes.count, 1)
            assertScope(try XCTUnwrap(fixture.deletes.first))
            XCTAssertEqual(fixture.setters, [false, true])
            XCTAssertTrue(fixture.allowed)
            XCTAssertFalse(fixture.policyViolation)
            XCTAssertTrue(fixture.reads.isEmpty)
            XCTAssertTrue(fixture.updates.isEmpty)
            XCTAssertTrue(fixture.adds.isEmpty)
        }
    }

    func testDeniedDeleteDoesNotRetryAndRestoresPolicy() {
        let fixture = Fixture()
        fixture.deleteStatus = errSecInteractionNotAllowed
        XCTAssertThrowsError(try fixture.store().delete(account: "synthetic-account")) {
            XCTAssertEqual($0 as? WhereKeyError, .authorizationRequired("synthetic-account"))
        }
        XCTAssertEqual(fixture.deletes.count, 1)
        XCTAssertTrue(fixture.allowed)
    }

    func testInvalidAccountDoesNotCallAnySecurityOperation() {
        for account in ["", "synthetic\u{0}account", "synthetic\naccount", String(repeating: "a", count: 1_025)] {
            let fixture = Fixture()
            let store = fixture.store()
            XCTAssertThrowsError(try store.read(account: account))
            XCTAssertThrowsError(try store.save("synthetic", account: account))
            XCTAssertThrowsError(try store.delete(account: account))
            XCTAssertTrue(fixture.setters.isEmpty)
            XCTAssertTrue(fixture.reads.isEmpty)
            XCTAssertTrue(fixture.updates.isEmpty)
            XCTAssertTrue(fixture.adds.isEmpty)
            XCTAssertTrue(fixture.deletes.isEmpty)
        }
    }

    func testFailedPolicyGetOrSetNeverAccessesSecrets() {
        let getFailure = Fixture()
        getFailure.getStatus = errSecParam
        XCTAssertThrowsError(try getFailure.store().read(account: "synthetic-account"))
        XCTAssertTrue(getFailure.reads.isEmpty)
        XCTAssertTrue(getFailure.setters.isEmpty)
        let setFailure = Fixture()
        setFailure.setterStatuses = [errSecParam, errSecSuccess]
        XCTAssertThrowsError(try setFailure.store().read(account: "synthetic-account", interactive: true))
        XCTAssertTrue(setFailure.reads.isEmpty)
        XCTAssertEqual(setFailure.setters, [true, false])
        XCTAssertFalse(setFailure.allowed)
    }

    func testRestoreFailureFailsClosedAndAttemptsQuietFallback() {
        let fixture = Fixture()
        fixture.allowed = false
        fixture.setterStatuses = [errSecSuccess, errSecParam, errSecSuccess]
        XCTAssertThrowsError(try fixture.store().read(account: "synthetic-account", interactive: true)) {
            XCTAssertEqual($0 as? WhereKeyError, .keychain(errSecParam))
            XCTAssertFalse($0.localizedDescription.contains("synthetic-key-value"))
        }
        XCTAssertEqual(fixture.reads.count, 1)
        XCTAssertEqual(fixture.setters, [true, false, false])
        XCTAssertFalse(fixture.allowed)
    }

    func testAllStoreInstancesSerializeTheirInteractionWindows() {
        let lock = NSLock()
        var allowed = true
        var active = 0
        var maximumActive = 0
        var policyMismatch = false
        var errors = 0
        let interaction = KeychainInteractionOperations(getAllowed: { (errSecSuccess, allowed) }, setAllowed: {
            allowed = $0
            return errSecSuccess
        })
        let operations = KeychainOperations(read: { query in
            lock.lock()
            active += 1
            maximumActive = max(maximumActive, active)
            if (query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == allowed { policyMismatch = true }
            lock.unlock()
            usleep(2_000)
            lock.lock(); active -= 1; lock.unlock()
            return (errSecSuccess, Data("synthetic".utf8))
        }, update: { _, _ in errSecParam }, add: { _ in errSecParam }, delete: { _ in errSecParam })
        let first = KeychainStore(operations: operations, interaction: interaction)
        let second = KeychainStore(operations: operations, interaction: interaction)
        let group = DispatchGroup()
        for index in 0..<24 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do { _ = try (index.isMultiple(of: 2) ? first : second).read(account: "synthetic-account", interactive: index.isMultiple(of: 3)) }
                catch { lock.lock(); errors += 1; lock.unlock() }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(errors, 0)
        XCTAssertEqual(maximumActive, 1)
        XCTAssertFalse(policyMismatch)
        XCTAssertTrue(allowed)
    }
}
