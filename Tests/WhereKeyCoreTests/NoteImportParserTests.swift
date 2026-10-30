import XCTest
@testable import WhereKeyCore

final class NoteImportParserTests: XCTestCase {
    func testCompletesDeepSeekOfficialDetailsFromInformalNote() throws {
        let secret = "sk-deepseek-secret-123456789"
        let candidates = NoteImportParser.parse("""
        DeepSeek 官网
        key: \(secret)
        """)

        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidate.draft.name, "DeepSeek")
        XCTAssertEqual(candidate.draft.kind, .apiKey)
        XCTAssertEqual(candidate.draft.baseURL, "https://api.deepseek.com")
        XCTAssertEqual(candidate.draft.baseURLVariable, "DEEPSEEK_BASE_URL")
        XCTAssertEqual(candidate.draft.credentials.first?.environmentVariable, "DEEPSEEK_API_KEY")
        XCTAssertEqual(candidate.draft.credentials.first?.secret, secret)
        XCTAssertFalse(candidate.sourcePreview.contains(secret))
    }

    func testParsesMixedOnlineAndInternalServices() throws {
        let candidates = NoteImportParser.parse("""
        OpenAI
        OPENAI_API_KEY=sk-proj-openai-secret-123456

        内网 ASR
        URL: http://10.0.0.8:9000/v1/audio/transcriptions
        token: internal-asr-token-123456

        内网 Embedding
        http://10.0.0.9:8000/v1/embeddings
        API_KEY: embedding-token-123456
        """)

        XCTAssertEqual(candidates.count, 3)
        XCTAssertEqual(candidates[0].draft.name, "OpenAI")
        XCTAssertEqual(candidates[0].draft.baseURL, "https://api.openai.com/v1")
        XCTAssertEqual(candidates[1].draft.name, "内网 ASR")
        XCTAssertEqual(candidates[1].draft.baseURL, "http://10.0.0.8:9000/v1/audio/transcriptions")
        XCTAssertEqual(candidates[2].draft.name, "内网 Embedding")
        XCTAssertEqual(candidates[2].draft.baseURL, "http://10.0.0.9:8000/v1/embeddings")
    }

    func testMergesMultipleKeysForTheSameProvider() throws {
        let candidates = NoteImportParser.parse("""
        Groq
        key: gsk_first-secret-123456789

        Groq
        key: gsk_second-secret-123456789
        """)

        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidate.draft.credentials.count, 2)
        XCTAssertTrue(candidate.draft.credentials[0].isDefault)
        XCTAssertFalse(candidate.draft.credentials[1].isDefault)
        XCTAssertEqual(candidate.draft.credentials[1].alias, "key-2")
    }

    func testExtractsSecretFromCurlAndOnlyKeepsRedactedPreview() throws {
        let secret = "curl-secret-token-123456"
        let candidates = NoteImportParser.parse("""
        内网搜索
        curl http://10.0.0.5:4000/search -H 'Authorization: Bearer \(secret)' -d '{"q":"test"}'
        """)

        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(candidate.draft.kind, .curl)
        XCTAssertEqual(candidate.draft.name, "内网搜索")
        XCTAssertEqual(candidate.draft.credentials.first?.secret, secret)
        XCTAssertTrue(candidate.draft.curlTemplate.contains("{{secret:default}}"))
        XCTAssertFalse(candidate.sourcePreview.contains(secret))
    }

    func testURLWithoutKeyBecomesConfirmableGetCurl() throws {
        let candidates = NoteImportParser.parse("""
        内网健康检查
        http://10.0.0.20:8080/health
        """)

        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(candidate.draft.kind, .curl)
        XCTAssertTrue(candidate.draft.credentials.isEmpty)
        XCTAssertEqual(candidate.draft.curlTemplate, "curl 'http://10.0.0.20:8080/health'")
    }

    func testNormalizesInternalURLWithoutSchemeAndFindsBareToken() throws {
        let candidates = NoteImportParser.parse("""
        内网 ASR
        10.0.0.8:9000/v1/audio/transcriptions
        raw-token-1234567890
        """)

        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(candidate.draft.kind, .apiKey)
        XCTAssertEqual(candidate.draft.baseURL, "http://10.0.0.8:9000/v1/audio/transcriptions")
        XCTAssertEqual(candidate.draft.credentials.first?.secret, "raw-token-1234567890")
    }

    func testAzureOpenAIDoesNotInventPublicOpenAIEndpoint() throws {
        let candidates = NoteImportParser.parse("""
        Azure OpenAI
        AZURE_OPENAI_API_KEY=azure-key-1234567890
        """)

        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(candidate.draft.name, "Azure OpenAI")
        XCTAssertEqual(candidate.draft.baseURL, "")
        XCTAssertEqual(candidate.draft.credentials.first?.environmentVariable, "AZURE_OPENAI_API_KEY")
    }
}
