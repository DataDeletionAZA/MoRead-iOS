import XCTest
@testable import MoReadCore

final class BookCoverSearchTests: XCTestCase {
    func testImageRequestsAndProviderResponses() throws {
        var settings = WebSearchSettings(); settings.enabled = true
        for provider in WebSearchProvider.allCases {
            settings.provider = provider
            let request = try BookCoverSearch.imageRequest(settings: settings, key: "test-key", query: "海岸 封面")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(request.url?.absoluteString, provider.searchEndpoint)
            XCTAssertEqual(body["query"] as? String, "海岸 封面")
            XCTAssertEqual(request.value(forHTTPHeaderField: provider == .exa ? "x-api-key" : "Authorization"), provider == .exa ? "test-key" : "Bearer test-key")
            if provider == .firecrawl { XCTAssertEqual((body["sources"] as? [[String: String]])?.first?["type"], "images"); XCTAssertEqual(body["limit"] as? Int, 12) }
            if provider == .exa { XCTAssertEqual(((body["contents"] as? [String: Any])?["extras"] as? [String: Int])?["imageLinks"], 5) }
            if provider == .tavily { XCTAssertEqual(body["include_images"] as? Bool, true); XCTAssertEqual(body["include_image_descriptions"] as? Bool, true) }
        }
        settings.enabled = false
        XCTAssertThrowsError(try BookCoverSearch.imageRequest(settings: settings, key: "test", query: "海岸"))
        settings.enabled = true
        XCTAssertThrowsError(try BookCoverSearch.imageRequest(settings: settings, key: "", query: "海岸"))
        XCTAssertThrowsError(try BookCoverSearch.imageRequest(settings: settings, key: "test", query: String(repeating: "a", count: 501)))
        let fire = try BookCoverSearch.decodeImages(Data(#"{"data":{"images":[{"imageUrl":"http://img.example/cover.jpg","url":"https://books.example/coast","title":"海岸"},{"imageUrl":"https://img.example/cover.jpg"},{"imageUrl":"file:///private/cover"}]}}"#.utf8), provider: .firecrawl)
        XCTAssertEqual(fire.count, 1); XCTAssertEqual(fire[0].imageURL, "https://img.example/cover.jpg"); XCTAssertEqual(fire[0].pageURL, "https://books.example/coast")
        let exa = try BookCoverSearch.decodeImages(Data(#"{"results":[{"url":"https://books.example/coast","title":"海岸","image":"https://img.example/a.jpg","extras":{"imageLinks":["https://img.example/b.jpg",{"imageUrl":"https://img.example/c.jpg"},"https://img.example/a.jpg"]}}]}"#.utf8), provider: .exa)
        XCTAssertEqual(exa.count, 3); XCTAssertTrue(exa.allSatisfy { $0.pageURL == "https://books.example/coast" })
        let tavily = try BookCoverSearch.decodeImages(Data(#"{"images":[{"url":"https://img.example/a.jpg","description":"封面"}],"results":[{"url":"https://books.example/coast","images":["https://img.example/b.jpg"]}]}"#.utf8), provider: .tavily)
        XCTAssertEqual(tavily.count, 2); XCTAssertEqual(tavily[0].title, "封面"); XCTAssertEqual(tavily[1].pageURL, "https://books.example/coast")
        let many = try JSONSerialization.data(withJSONObject: ["images": (0..<200).map { "https://img.example/\($0).jpg" }])
        XCTAssertEqual(try BookCoverSearch.decodeImages(many, provider: .tavily).count, 30)
        for bad in ["{}", "{\"error\":\"private provider error\"}", "{\"success\":false,\"images\":[]}"] {
            XCTAssertThrowsError(try BookCoverSearch.decodeImages(Data(bad.utf8), provider: .tavily))
        }
        XCTAssertThrowsError(try BookCoverSearch.imageURL("https://secret:password@books.example/a.jpg"))
        XCTAssertThrowsError(try BookCoverSearch.imageURL("data:image/png;base64,test"))
    }
    func testCatalogFallbackInputsQueriesAndCancellation() async throws {
        let queries = try BookCoverSearch.queries(title: "海岸", author: "林舟", generated: "1. official book cover\n2. 海岸 林舟 封面\n3. 不相关\n4. extra cover")
        XCTAssertEqual(queries.count, 3); XCTAssertTrue(queries.allSatisfy { $0.contains("海岸") }); XCTAssertTrue(queries.last!.contains("林舟"))
        XCTAssertEqual(try BookCoverSearch.queries(title: "海岸", author: "", generated: "没有查询").count, 1)
        XCTAssertThrowsError(try BookCoverSearch.queries(title: "", author: ""))
        XCTAssertThrowsError(try BookCoverSearch.queries(title: String(repeating: "a", count: 241), author: ""))
        XCTAssertThrowsError(try BookCoverSearch.queries(title: "海岸\n后续", author: ""))
        let open = try BookCoverSearch.catalogRequest(title: "A & B", author: "林舟", google: false)
        let items = try XCTUnwrap(URLComponents(url: XCTUnwrap(open.url), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "title" }?.value, "A & B")
        XCTAssertEqual(items.first { $0.name == "author" }?.value, "林舟")
        let covers = try BookCoverSearch.decodeCatalog(Data(#"{"docs":[{"cover_i":42,"title":"海岸","author_name":["林舟"],"key":"/works/OL42W"},{"title":"No cover"},{"cover_i":true},{"cover_i":0},{"cover_i":1.5},{"cover_i":42}]}"#.utf8), google: false, title: "海岸")
        XCTAssertEqual(covers.count, 1); XCTAssertEqual(covers[0].imageURL, "https://covers.openlibrary.org/b/id/42-L.jpg?default=false"); XCTAssertEqual(covers[0].pageURL, "https://openlibrary.org/works/OL42W")
        let google = try BookCoverSearch.decodeCatalog(Data(#"{"items":[{"volumeInfo":{"title":"海岸","authors":["林舟"],"imageLinks":{"smallThumbnail":"https://img.example/s.jpg","large":"http://img.example/l.jpg"}}}]}"#.utf8), google: true, title: "海岸")
        XCTAssertEqual(google.first?.imageURL, "https://img.example/l.jpg")
        XCTAssertTrue(try BookCoverSearch.decodeCatalog(Data(#"{"totalItems":0}"#.utf8), google: true, title: "海岸").isEmpty)
        XCTAssertThrowsError(try BookCoverSearch.decodeCatalog(Data(#"{"error":{"code":429}}"#.utf8), google: true, title: "海岸"))
        let cancelled = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await BookCoverSearch.search(title: "海岸", author: "", settings: .init(), key: "") }
        do { _ = try await cancelled.value; XCTFail("Cancelled lookup should not run") } catch is CancellationError {} catch { XCTFail("Unexpected cancellation error") }
    }
}
