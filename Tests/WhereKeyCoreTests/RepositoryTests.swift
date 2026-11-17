import Foundation
import XCTest
@testable import WhereKeyCore

private final class MemorySecrets: SecretStoring {
    var values: [String: String] = [:]
    var readAccounts: [String] = []
    func save(_ value: String, account: String) throws { values[account] = value }
    func read(account: String) throws -> String {
        readAccounts.append(account)
        guard let value = values[account] else { throw WhereKeyError.notFound("missing") }
        return value
    }
    func delete(account: String) throws { values.removeValue(forKey: account) }
}

final class RepositoryTests: XCTestCase {
    private var directory: URL!
    private var secrets: MemorySecrets!
    private var repository: WhereKeyRepository!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("WhereKeyTests-\(UUID().uuidString)")
        secrets = MemorySecrets()
        repository = try WhereKeyRepository(metadataStore: MetadataStore(directoryURL: directory), keychain: secrets)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testCatalogNeverContainsSecretAndDefaultKeyIsUsed() throws {
        let secret = "wk-super-secret"
        var draft = ServiceDraft(name: "Example", environmentVariable: "EXAMPLE_KEY")
        draft.credentials = [
            CredentialDraft(alias: "production", environmentVariable: "EXAMPLE_KEY", secret: secret, isDefault: true),
            CredentialDraft(alias: "test", environmentVariable: "EXAMPLE_KEY", secret: "test-secret", isDefault: false),
        ]
        try repository.save(draft)

        let encoded = try JSONEncoder().encode(repository.catalog())
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains(secret))
        XCTAssertTrue(text.contains("production"))

        let prepared = try repository.prepareRun(service: "Example", keyAlias: nil, cwd: directory.path)
        XCTAssertEqual(prepared.environment["EXAMPLE_KEY"], secret)
        XCTAssertEqual(prepared.credentialAlias, "production")
        XCTAssertEqual(repository.snapshot().projects.count, 1)
        XCTAssertEqual(repository.snapshot().usages.count, 1)
    }

    func testDeletingServicePreservesProjectUsageTombstone() throws {
        let credential = CredentialDraft(alias: "default", environmentVariable: "API_KEY", secret: "secret", isDefault: true)
        let serviceID = try repository.save(ServiceDraft(name: "Temporary", credentials: [credential]))
        _ = try repository.prepareRun(service: "Temporary", keyAlias: nil, cwd: directory.path)
        try repository.deleteService(serviceID)
        let state = repository.snapshot()
        XCTAssertTrue(state.services.isEmpty)
        XCTAssertTrue(state.credentials.isEmpty)
        XCTAssertEqual(state.projects.count, 1)
        XCTAssertEqual(state.usages.first?.serviceNameSnapshot, "Temporary")
        XCTAssertEqual(state.usages.first?.credentialAliasSnapshot, "default")
    }

    func testMetadataFileDoesNotContainSecret() throws {
        let secret = "never-write-this-value"
        let credential = CredentialDraft(alias: "default", environmentVariable: "API_KEY", secret: secret, isDefault: true)
        try repository.save(ServiceDraft(name: "NoLeak", credentials: [credential]))
        let metadata = try String(contentsOf: directory.appendingPathComponent("metadata.json"), encoding: .utf8)
        XCTAssertFalse(metadata.contains(secret))
        XCTAssertTrue(metadata.contains("NoLeak"))
    }

    func testBatchCheckDoesNotReadOrExecuteLegacyBusinessCurl() throws {
        let serviceID = UUID()
        let service = ServiceRecord(id: serviceID, name: "Legacy POST", kind: .curl,
                                    checkMode: .manual, allowsLegacyCurlCheck: true, hasCurlTemplate: true)
        let store = MetadataStore(directoryURL: directory)
        try store.save(MetadataState(services: [service]))
        let account = KeychainStore.curlAccount(serviceID)
        secrets.values[account] = "curl -X POST https://example.test/business"
        let legacy = try WhereKeyRepository(metadataStore: store, keychain: secrets)
        let results = legacy.checkAll()
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.1.status, .unchecked)
        XCTAssertFalse(secrets.readAccounts.contains(account), "Batch checking must not even read the business request")
    }

    func testBatchCheckSkipsIndependentPostBeforeReadingCredentials() throws {
        let serviceID = UUID(), keyID = UUID()
        let service = ServiceRecord(id: serviceID, name: "POST verification", kind: .apiKey,
                                    checkMode: .manual, credentialIDs: [keyID], defaultCredentialID: keyID,
                                    hasValidationRequest: true)
        let credential = CredentialRecord(id: keyID, serviceID: serviceID, alias: "default", environmentVariable: "TEST_KEY", maskedSuffix: "")
        let store = MetadataStore(directoryURL: directory)
        try store.save(MetadataState(services: [service], credentials: [credential]))
        secrets.values[KeychainStore.validationAccount(serviceID)] = "curl -XPOST https://example.test/verify -H 'X-Key: {{key}}'"
        secrets.values[KeychainStore.credentialAccount(keyID)] = "fixture-only-secret"
        let repository = try WhereKeyRepository(metadataStore: store, keychain: secrets)
        let results = repository.checkAll()
        XCTAssertEqual(results.first?.1.status, .unchecked)
        XCTAssertFalse(secrets.readAccounts.contains(KeychainStore.credentialAccount(keyID)))
    }

}
