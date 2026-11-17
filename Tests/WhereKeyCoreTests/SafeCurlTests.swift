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

    func testNormalizesSupportedAttachedOptionValues() throws {
        let parsed = try SafeCurl.parse("curl -XPOST --header='Content-Type: application/json' -H'X-Test: literal' --data='{\"ok\":true}' https://example.test")
        XCTAssertEqual(Array(parsed.arguments.prefix(8)), ["--request", "POST", "--header", "Content-Type: application/json", "--header", "X-Test: literal", "--data", "{\"ok\":true}"])
        XCTAssertFalse(SafeCurl.isReadOnly("curl -XPOST https://example.test"))
        XCTAssertFalse(SafeCurl.isReadOnly("curl --request=POST https://example.test"))
        XCTAssertTrue(SafeCurl.isReadOnly("curl -XGET -H'X-Test: literal' https://example.test"))
        XCTAssertTrue(try SafeCurl.parse("curl -k https://example.test").containsInsecureTLS)
        XCTAssertTrue(try SafeCurl.parse("curl -sS https://example.test").arguments.contains("--show-error"))
        XCTAssertTrue(try SafeCurl.parse("curl -fsSL https://example.test").arguments.contains("--location"))
    }

    func testRejectsFileOptionAliasesAndAbbreviations() {
        // Parse only. None of these fixtures is ever executed by curl.
        let unsafeOptions = [
            "--config=/tmp/fixture", "-K/tmp/fixture", "--conf /tmp/fixture",
            "--output=/tmp/fixture", "-o/tmp/fixture", "--remote-name",
            "--upload-file=/tmp/fixture", "-T/tmp/fixture", "--trace=/tmp/fixture",
            "--write-out=@/tmp/fixture", "-w@/tmp/fixture", "--cookie-jar=/tmp/fixture",
            "--netrc", "--netrc-file=/tmp/fixture", "--cacert=/tmp/fixture",
            "--cert /tmp/fixture", "--key /tmp/fixture",
            "--form 'field=@/tmp/fixture'", "-F'field=</tmp/fixture'",
            "--data=@/tmp/fixture", "-d@/tmp/fixture", "--data-binary=@/tmp/fixture",
            "--data-urlencode 'field@/tmp/fixture'", "--json=@/tmp/fixture",
            "--header=@/tmp/fixture", "-H@/tmp/fixture", "--url=file:///tmp/fixture",
            "--proto=all", "--proto-redir=file", "--next", "--location-trusted",
            "--not-a-supported-option", "-sSo/tmp/fixture",
        ]
        for option in unsafeOptions {
            XCTAssertThrowsError(try SafeCurl.parse("curl \(option) https://example.test"), option)
        }
        XCTAssertThrowsError(try SafeCurl.parse("curl --url=https://example.test https://second.test"))
        XCTAssertThrowsError(try SafeCurl.parse("curl --header='X-Test: value\nInjected: header' https://example.test"))
    }

    func testAllowsLiteralBodyValuesWithoutReadingFiles() throws {
        let raw = try SafeCurl.parse("curl --data-raw='@literal' https://example.test")
        XCTAssertTrue(raw.arguments.contains("@literal"))
        let form = try SafeCurl.parse("curl --form-string='field=@literal' https://example.test")
        XCTAssertTrue(form.arguments.contains("field=@literal"))
        let encoded = try SafeCurl.parse("curl --data-urlencode='email=user@example.test' https://example.test")
        XCTAssertTrue(encoded.arguments.contains("email=user@example.test"))
        XCTAssertFalse(SafeCurl.isReadOnly("curl -XGET --data-raw='body' https://example.test"))
    }

    func testExpandedSecretsCannotBecomeFileReadingArguments() throws {
        // Model already-expanded credential values without invoking curl.
        for (option, value) in [("--header", "@/tmp/fixture"), ("--data", "@/tmp/fixture"),
                                ("--data-binary", "@/tmp/fixture"), ("--json", "@/tmp/fixture"),
                                ("--data-urlencode", "field@/tmp/fixture")] {
            XCTAssertThrowsError(try SafeCurl.validateExpandedArguments([option, value, "https://example.test"])) { error in
                XCTAssertFalse(error.localizedDescription.contains(value))
            }
        }
        XCTAssertThrowsError(try SafeCurl.validateExpandedArguments(["--url", "file:///tmp/fixture"]))
        XCTAssertNoThrow(try SafeCurl.validateExpandedArguments(["--header", "X-Key: @literal", "--data-raw", "@literal", "https://example.test"]))
        XCTAssertNoThrow(try SafeCurl.validateExpandedArguments(["--data-urlencode", "email=user@example.test", "https://example.test"]))
    }

}
