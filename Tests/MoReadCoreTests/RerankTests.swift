import XCTest
@testable import MoReadCore

final class RerankTests: XCTestCase {
    func testRequestBudgetsEndpointsAndStrictRanking() throws {
        var provider = AIProvider(); provider.model = "rerank-model"
        for (base, path) in [("https://example.invalid/v1/chat/completions", "/v1/rerank"), ("https://example.invalid/v2/rerank", "/v2/rerank"), ("https://example.invalid", "/rerank")] {
            provider.baseURL = base
            let request = try RerankClient.request(provider: provider, key: "test-only", query: "灯塔在哪", documents: ["海边", "山顶"])
            XCTAssertEqual(request.url?.path, path); XCTAssertEqual(request.timeoutInterval, 5)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-only")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(body["documents"] as? [String], ["海边", "山顶"]); XCTAssertEqual(body["top_n"] as? Int, 2)
            XCTAssertEqual(body["return_documents"] as? Bool, false)
        }
        XCTAssertEqual(try RerankClient.request(provider: provider, key: "test-only", endpoint: "v2/rank", query: "灯塔", documents: ["海边", "山顶"]).url?.path, "/v2/rank")
        for endpoint in ["../rank", "https://elsewhere.invalid", "rerank?key=bad", "rank#fragment"] {
            XCTAssertThrowsError(try RerankClient.request(provider: provider, key: "test-only", endpoint: endpoint, query: "灯塔", documents: ["海边", "山顶"]))
        }
        XCTAssertThrowsError(try RerankClient.request(provider: provider, key: "test-only", query: String(repeating: "中", count: 513), documents: ["海边", "山顶"]))
        XCTAssertThrowsError(try RerankClient.request(provider: provider, key: "test-only", query: "灯塔", documents: Array(repeating: String(repeating: "中", count: 800), count: 16)))
        let ordered = Data(#"{"results":[{"index":0,"relevance_score":0.1},{"index":1,"relevance_score":0.9}]}"#.utf8)
        XCTAssertEqual(try RerankClient.decode(ordered, count: 2), [1,0])
        for invalid in [#"{"index":0,"relevance_score":0.5}"#, #"{"index":true,"relevance_score":0.5}"#, #"{"index":1.2,"relevance_score":0.5}"#, #"{"index":2,"relevance_score":0.5}"#, #"{"index":1,"relevance_score":true}"#, #"{"index":1,"relevance_score":"NaN"}"#] {
            XCTAssertThrowsError(try RerankClient.decode(Data(("{\"results\":[{\"index\":0,\"relevance_score\":1}," + invalid + "]}").utf8), count: 2))
        }
        XCTAssertThrowsError(try RerankClient.decode(Data("{\"results\":[]}".utf8), count: 2))
    }
    func testOrderingPreservesPinnedSourceTailAndUnicodeBudget() async throws {
        let book = UUID()
        let passages = (0..<30).map { index in SourcePassage(bookID: book, chapter: .init(id: index, title: "章", text: String(repeating: "🌙", count: 1000)), offset: 0, text: String(repeating: "🌙", count: 1000)) }
        let result = try await RerankClient.reorder(query: String(repeating: "🌙", count: 300), passages: passages, pinnedID: passages[0].id) { query, documents in
            XCTAssertEqual(query.utf16.count, 512); XCTAssertEqual(documents.count, 15)
            XCTAssertEqual(documents.reduce(0) { $0 + $1.utf16.count }, 12000)
            XCTAssertTrue(documents.allSatisfy { $0.utf16.count == 800 && !$0.contains("�") })
            return Array(documents.indices.reversed())
        }
        XCTAssertEqual(result, [passages[0]] + Array(passages[1...15].reversed()) + Array(passages[16...]))
        do { _ = try await RerankClient.reorder(query: "问题", passages: passages) { _, _ in [0,0] }; XCTFail("Invalid ranking must fail") } catch {}
        let single = try await RerankClient.reorder(query: "问题", passages: [passages[0]]) { _, _ in XCTFail("Single source needs no request"); return [] }
        XCTAssertEqual(single, [passages[0]])
    }
    func testReorderedCitationsAndReadingScopeValidation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let chapters = [Chapter(id: 0, title: "First", text: "lighthouse first clue."), Chapter(id: 1, title: "Second", text: "lighthouse second clue."), Chapter(id: 2, title: "Future", text: "lighthouse secret identity.")]
        var book = try store.importBook(title: "灯塔", chapters: chapters); book.readThrough = .init(chapter: 1, offset: chapters[1].text.utf16.count)
        var context = try CompanionContextBuilder.build(query: "lighthouse", books: [book], currentBook: nil, store: store)
        XCTAssertEqual(context.passages.count, 2)
        let ordered = try await RerankClient.reorder(query: "lighthouse", passages: context.passages) { _, documents in
            XCTAssertFalse(documents.contains { $0.contains("secret") }); return [1,0]
        }
        context.order(ordered, books: [book])
        XCTAssertEqual(context.passages.first?.chapter, 1)
        XCTAssertTrue(context.text.hasPrefix("【来源 1】《灯塔》Second\nlighthouse second clue."))
        XCTAssertFalse(context.text.contains("secret")); XCTAssertNoThrow(try context.validateSources(books: [book]))
        book.readThrough = .init(chapter: 0, offset: 2)
        XCTAssertThrowsError(try context.validateSources(books: [book]))
        XCTAssertThrowsError(try context.validateSources(books: []))
        XCTAssertNil(try JSONDecoder().decode(CompanionSettings.self, from: Data(#"{"providers":[],"userName":"读者"}"#.utf8)).rerank)
    }
}
