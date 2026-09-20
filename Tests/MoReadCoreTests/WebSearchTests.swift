import XCTest
@testable import MoReadCore

final class WebSearchTests: XCTestCase {
    private let search = ChatToolCall(id: "search", name: "web_search", arguments: #"{"query":"灯塔历史","limit":3}"#)
    private let scrape = ChatToolCall(id: "scrape", name: "web_scrape", arguments: #"{"url":"https://example.org/article"}"#)
    func testProviderRequestsOptInDepthAndEndpointIsolation() throws {
        var settings = WebSearchSettings()
        XCTAssertThrowsError(try WebSearchClient.request(settings: settings, key: "test-only", call: search))
        XCTAssertFalse(try ReaderTools.specs(currentBook: UUID(), memory: false).contains { WebSearchClient.tools.contains($0.name) })
        XCTAssertFalse(try ReaderTools.specs(currentBook: nil, memory: false, webSearch: true).contains { WebSearchClient.tools.contains($0.name) })
        XCTAssertEqual(try ReaderTools.specs(currentBook: UUID(), memory: false, webSearch: true, enabled: ["web_scrape"]).map(\.name), ["web_scrape"])
        settings.enabled = true; settings.advancedSearch = true; settings.advancedExtract = true
        for provider in WebSearchProvider.allCases {
            settings.provider = provider
            let request = try WebSearchClient.request(settings: settings, key: "test-only", call: search)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(request.url?.absoluteString, provider.searchEndpoint)
            XCTAssertEqual(request.value(forHTTPHeaderField: provider == .exa ? "x-api-key" : "Authorization"), provider == .exa ? "test-only" : "Bearer test-only")
            XCTAssertEqual(body["query"] as? String, "灯塔历史")
            XCTAssertEqual(body[provider == .firecrawl ? "limit" : provider == .exa ? "numResults" : "max_results"] as? Int, 3)
            let read = try WebSearchClient.request(settings: settings, key: "test-only", call: scrape)
            XCTAssertEqual(read.url?.absoluteString, provider.scrapeEndpoint)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(read.httpBody)) as? [String: Any])
            if provider == .tavily { XCTAssertEqual(body["search_depth"] as? String, "advanced"); XCTAssertEqual(payload["extract_depth"] as? String, "advanced"); XCTAssertEqual(body["include_answer"] as? Bool, false) }
            if provider == .exa { XCTAssertEqual(payload["urls"] as? [String], ["https://example.org/article"]) }
            settings.searchEndpoint = "https://proxy.example/" + provider.rawValue + "/search"
        }
        for provider in WebSearchProvider.allCases { settings.provider = provider; XCTAssertEqual(try WebSearchClient.request(settings: settings, key: "test-only", call: search).url?.path, "/" + provider.rawValue + "/search") }
        for invalid in ["http://api.example/search", "https://user:pass@api.example/search", "https://api.example/search?key=private", "file:///tmp/test", "https://api.example/search#fragment"] {
            settings.searchEndpoint = invalid; XCTAssertThrowsError(try WebSearchClient.request(settings: settings, key: "test-only", call: search))
        }
        settings.searchEndpoint = settings.provider.searchEndpoint
        for args in [#"{"query":" "}"#, #"{"query":"test","limit":true}"#, #"{"query":"test","limit":9}"#, #"{"query":"test","limit":1.5}"#] {
            XCTAssertThrowsError(try WebSearchClient.request(settings: settings, key: "test-only", call: .init(id: "bad", name: "web_search", arguments: args)))
        }
        for url in ["javascript:alert(1)", "data:text/html,a", "https://user:pass@example.org", "https://example.org/a\nb", "https://example.org/\0x"] { XCTAssertThrowsError(try WebSearchClient.webURL(url)) }
        XCTAssertThrowsError(try WebSearchClient.request(settings: settings, key: "x\r\ny", call: search))
    }
    func testResponsesSourceLinksBudgetsAndFailures() throws {
        let fixtures: [(WebSearchProvider, String)] = [
            (.firecrawl, #"{"data":{"web":[{"title":"灯塔","url":"https://example.org/a","description":"  near\n the sea  "},{"url":"https://example.org/a"},{"url":"javascript:alert(1)"}]}}"#),
            (.firecrawl, #"{"data":[{"title":"灯塔","url":"https://example.org/a","markdown":"near the sea"}]}"#),
            (.exa, #"{"results":[{"title":"灯塔","url":"https://example.org/a","text":"near the sea"}]}"#),
            (.tavily, #"{"results":[{"title":"灯塔","url":"https://example.org/a","content":"near the sea"}]}"#)
        ]
        for (provider, raw) in fixtures {
            let result = try WebSearchClient.decode(Data(raw.utf8), provider: provider, call: search)
            XCTAssertEqual(result.pages.count, 1); XCTAssertEqual(result.pages[0].text, "near the sea")
            XCTAssertEqual(try WebSearchResult.decode(result.encoded()).pages[0].source.url, "https://example.org/a")
        }
        for provider in WebSearchProvider.allCases {
            let item: [String: Any] = ["metadata": ["sourceURL": "https://example.org/article", "title": "网页"], "text": String(repeating: "🌙", count: 12_000), "markdown": String(repeating: "🌙", count: 12_000), "raw_content": String(repeating: "🌙", count: 12_000)]
            let root: [String: Any] = provider == .firecrawl ? ["data": item] : ["results": [item]]
            let result = try WebSearchClient.decode(JSONSerialization.data(withJSONObject: root), provider: provider, call: scrape)
            XCTAssertEqual(result.pages[0].text.utf16.count, 20_000); XCTAssertFalse(result.pages[0].text.contains("�"))
            XCTAssertEqual(result.pages[0].source.url, "https://example.org/article")
            XCTAssertThrowsError(try WebSearchClient.decode(Data(#"{"results":[]}"#.utf8), provider: provider, call: scrape))
        }
        for raw in [#"{"error":"private server details"}"#, #"{"success":false,"data":{"web":[]}}"#, #"{}"#, #"{"results":null}"#] {
            XCTAssertThrowsError(try WebSearchClient.decode(Data(raw.utf8), provider: .firecrawl, call: search))
        }
        XCTAssertTrue(try WebSearchClient.decode(Data(#"{"results":[]}"#.utf8), provider: .exa, call: search).pages.isEmpty)
        XCTAssertThrowsError(try WebSearchClient.decode(Data(repeating: 32, count: 1_048_577), provider: .exa, call: search))
    }
    func testSettingsAndLinksSurviveBackupAndCancellationPreventsRequest() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("library"), library = try LibraryStore(root: root), store = try CompanionStore(root: root)
        let book = try library.importBook(title: "Book", chapters: [.init(id: 0, title: "Chapter", text: "Text")])
        var settings = CompanionSettings(), web = WebSearchSettings(); web.enabled = true; web.provider = .tavily; web.advancedExtract = true; web.searchEndpoint = "https://proxy.example/search"; settings.webSearch = web
        try store.save(settings)
        var chat = Conversation(title: "Web", bookID: book.id, characterID: UUID()), reply = ChatMessage(role: "assistant", content: "网页资料")
        var trace = ChatToolTrace(call: search, title: "搜索互联网"); trace.state = "succeeded"; trace.webSources = [.init(title: "Reference", url: "https://example.org/a")]
        reply.toolTrace = [trace]; chat.messages = [reply]; try store.save(chat)
        let zip = parent.appendingPathComponent("backup.zip"); _ = try await BackupArchive.create(root: root, output: zip)
        let prepared = try await BackupArchive.prepare(zip, beside: root); _ = try BackupArchive.activate(prepared, replacing: root)
        XCTAssertEqual(try CompanionStore(root: root).settings().webSearch, web); XCTAssertEqual(try CompanionStore(root: root).conversations(), [chat])
        trace.webSources = [trace.webSources![0], trace.webSources![0]]; chat.messages[0].toolTrace = [trace]; XCTAssertThrowsError(try store.save(chat))
        trace.webSources = [.init(title: "Bad", url: "javascript:alert(1)")]; chat.messages[0].toolTrace = [trace]; XCTAssertThrowsError(try store.save(chat))
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await WebSearchClient.run(settings: web, key: "test-only", call: self.search)
        }
        do { _ = try await cancelled.value; XCTFail("Cancelled search must stop") } catch is CancellationError {} catch { XCTFail("Expected cancellation, got \(error)") }
    }
}
