import XCTest
@testable import MoReadCore

final class GeminiVoiceCatalogTests: XCTestCase {
    func testEndpointPaginationAndProviderValidation() throws {
        var settings = CloudSpeechSettings(); settings.preset(.gemini)
        for base in ["https://example.com", "https://example.com/v1", "https://example.com/v1beta", "https://example.com/proxy/v1beta/interactions"] {
            settings.baseURL = base; settings.model = ""; settings.voice = ""
            let request = try GeminiVoiceCatalog.request(settings: settings, key: "test-key", pageToken: "next & +/https://untrusted.example")
            let url = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            XCTAssertEqual(url.host, "example.com"); XCTAssertEqual(url.path, base.contains("proxy") ? "/proxy/v1beta/voices" : "/v1beta/voices")
            XCTAssertEqual(request.httpMethod, "GET"); XCTAssertNil(request.httpBody)
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "test-key")
            XCTAssertEqual(url.queryItems?.first { $0.name == "page_size" }?.value, "1000")
            XCTAssertEqual(url.queryItems?.first { $0.name == "page_token" }?.value, "next & +/https://untrusted.example")
            XCTAssertNil(url.queryItems?.first { $0.name == "language_code" })
        }
        for base in ["http://example.com", "https://user:secret@example.com", "https://example.com/?key=secret"] {
            settings.baseURL = base; XCTAssertThrowsError(try GeminiVoiceCatalog.request(settings: settings, key: "test-key"))
        }
        settings.preset(.gemini); XCTAssertThrowsError(try GeminiVoiceCatalog.request(settings: settings, key: ""))
        XCTAssertThrowsError(try GeminiVoiceCatalog.request(settings: settings, key: "key\nheader"))
        settings.preset(.openAI); XCTAssertThrowsError(try GeminiVoiceCatalog.request(settings: settings, key: "key"))
    }
    func testPaginationDeduplicationAndMissingMetadata() async throws {
        var settings = CloudSpeechSettings(); settings.preset(.gemini)
        let fixture = CatalogFixture([
            #"{"voices":[{"id":"voice_custom","display_name":"书店旁白","gender":"female","language_code":"zh-CN","persona":"Warm","pitch":"low"},{"id":"Kore"}],"next_page_token":"next"}"#,
            #"{"voices":[{"id":"kore","display_name":"坚定音色"},{"id":"voice_second","gender":"male"},{"display_name":"没有编号"}]}"#
        ])
        let values = try await GeminiVoiceCatalog.list(settings: settings, key: "fixture", fetch: { try await fixture.fetch($0) })
        XCTAssertEqual(values.map(\.voiceId), ["voice_custom", "kore", "voice_second"])
        XCTAssertEqual(values.map(\.gender), ["FEMALE", "UNSPECIFIED", "MALE"])
        XCTAssertEqual(values[0].tags, "Gemini,zh-CN,Warm,low")
        XCTAssertEqual(values[1].displayName, "坚定音色"); XCTAssertEqual(values[2].displayName, "voice_second")
        let tokens = await fixture.tokens; XCTAssertEqual(tokens, ["", "next"])
        XCTAssertEqual(try GeminiVoiceCatalog.page(Data("{}".utf8)).voices, [])
    }
    func testBadPagesLoopsAndCancellationDoNotReturnPartialCatalog() async throws {
        for raw in [#"{"error":{"message":"private"}}"#, #"{"voices":false}"#, #"{"voices":[],"next_page_token":42}"#, "[]"] {
            XCTAssertThrowsError(try GeminiVoiceCatalog.page(Data(raw.utf8)))
        }
        XCTAssertThrowsError(try GeminiVoiceCatalog.page(Data(repeating: 32, count: GeminiVoiceCatalog.maximumPageBytes + 1)))
        var settings = CloudSpeechSettings(); settings.preset(.gemini)
        let loop = CatalogFixture([#"{"voices":[{"id":"first"}],"next_page_token":"again"}"#, #"{"voices":[],"next_page_token":"again"}"#])
        do { _ = try await GeminiVoiceCatalog.list(settings: settings, key: "fixture", fetch: { try await loop.fetch($0) }); XCTFail("Loop accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("分页")) }
        let secondPageError = CatalogFixture([#"{"voices":[{"id":"first"}],"next_page_token":"next"}"#, #"{"voices":true}"#])
        do { _ = try await GeminiVoiceCatalog.list(settings: settings, key: "fixture", fetch: { try await secondPageError.fetch($0) }); XCTFail("Partial catalog returned") } catch {}
        let task = Task { try await GeminiVoiceCatalog.list(settings: settings, key: "fixture") { _ in
            try await Task.sleep(for: .seconds(30)); return Data("{}".utf8)
        } }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation ignored") } catch is CancellationError {} catch { XCTFail("Unexpected cancellation error") }
    }
}
private actor CatalogFixture {
    let pages: [String]
    var tokens: [String] = []
    init(_ pages: [String]) { self.pages = pages }
    func fetch(_ request: URLRequest) throws -> Data {
        let token = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page_token" }?.value ?? ""
        tokens.append(token)
        guard tokens.count <= pages.count else { throw MoReadError.invalid("Unexpected page request") }
        return Data(pages[tokens.count - 1].utf8)
    }
}
