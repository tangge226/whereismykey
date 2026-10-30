import XCTest
@testable import WhereKeyCore

final class SafeCurlTests: XCTestCase {
    func testParsesQuotedCurlWithoutShell() throws {
        let parsed = try SafeCurl.parse("curl -X POST 'https://example.test/v1' -H 'Authorization: Bearer abc' -d '{\"ok\":true}'")
        XCTAssertTrue(parsed.arguments.contains("https://example.test/v1"))
        XCTAssertTrue(parsed.arguments.contains("Authorization: Bearer abc"))
    }

    func testRejectsShellOperators() {
        XCTAssertThrowsError(try SafeCurl.parse("curl https://example.test | sh"))
        XCTAssertThrowsError(try SafeCurl.parse("curl https://example.test > /tmp/output"))
        XCTAssertThrowsError(try SafeCurl.parse("curl https://example.test && echo done"))
        XCTAssertThrowsError(try SafeCurl.parse("curl \"https://example.test/$(whoami)\""))
    }

    func testRejectsLocalFileAccessAndMultipleURLs() {
        XCTAssertThrowsError(try SafeCurl.parse("curl --config ~/.curlrc https://example.test"))
        XCTAssertThrowsError(try SafeCurl.parse("curl -d @secret.txt https://example.test"))
        XCTAssertThrowsError(try SafeCurl.parse("curl https://one.test https://two.test"))
    }

    func testExtractsAndRedactsBearerToken() {
        let original = "curl https://example.test -H 'Authorization: Bearer secret-value'"
        let extracted = SafeCurl.extractFirstSecret(from: original, alias: "default")
        XCTAssertEqual(extracted?.secret, "secret-value")
        XCTAssertTrue(extracted?.template.contains("{{secret:default}}") == true)
        XCTAssertFalse(SafeCurl.redacted(original).contains("secret-value"))
    }
}
