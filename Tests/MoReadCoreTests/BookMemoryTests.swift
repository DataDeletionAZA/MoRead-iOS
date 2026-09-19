import XCTest
@testable import MoReadCore

private actor EmbeddingRecorder {
    var inputs: [String] = []
    func encode(_ texts: [String]) -> [[Float]] {
        inputs += texts
        return texts.map { $0.contains("灯塔") ? [1, 0] : [0, 1] }
    }
    func recorded() -> [String] { inputs }
}

final class BookMemoryTests: XCTestCase {
    func testProtocolsValidateAndReorderVectors() throws {
        for dialect in [AIProtocol.openAI, .responses, .gemini] {
            var provider = AIProvider(); provider.dialect = dialect; provider.model = "embedding-model"
            provider.baseURL = "https://example.invalid"
            let request = try EmbeddingClient.request(provider: provider, key: "test-only", texts: ["已读原文"])
            XCTAssertNil(request.url?.query)
            XCTAssertFalse(request.url!.absoluteString.contains("test-only"))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            if dialect == .gemini {
                XCTAssertEqual(request.url?.path, "/v1beta/models/embedding-model:batchEmbedContents")
                XCTAssertNotNil(body["requests"]); XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "test-only")
            } else {
                XCTAssertEqual(request.url?.path, "/v1/embeddings")
                XCTAssertEqual(body["input"] as? [String], ["已读原文"])
                for suffix in ["/v1/chat/completions", "/v1/responses", "/v1/embeddings", "/embeddings"] {
                    provider.baseURL = "https://example.invalid" + suffix
                    XCTAssertEqual(try EmbeddingClient.request(provider: provider, key: "test-only", texts: ["文本"]).url?.path, "/v1/embeddings")
                }
            }
        }
        let ordered = try EmbeddingClient.decode(Data(#"{"data":[{"index":1,"embedding":[0,4]},{"index":0,"embedding":[3,0]}]}"#.utf8), dialect: .openAI, count: 2)
        XCTAssertEqual(ordered, [[1, 0], [0, 1]])
        XCTAssertEqual(try EmbeddingClient.decode(Data(#"{"embeddings":[{"values":[0,4]}]}"#.utf8), dialect: .gemini, count: 1), [[0, 1]])
        for value in [#"{"index":true,"embedding":[1,0]}"#, #"{"index":0.5,"embedding":[1,0]}"#, #"{"index":0,"embedding":[true,0]}"#, #"{"index":0,"embedding":[0,0]}"#] {
            XCTAssertThrowsError(try EmbeddingClient.decode(Data(("{\"data\":[" + value + "]}").utf8), dialect: .openAI, count: 1))
        }
        XCTAssertThrowsError(try EmbeddingClient.normalized([.infinity, 1]))
        var bad = AIProvider(); bad.model = "m"; bad.baseURL = "https://example.invalid?key=secret"
        XCTAssertThrowsError(try EmbeddingClient.request(provider: bad, key: "test-only", texts: ["文本"]))
    }

    func testReadBoundaryResumeRankingBackupAndClear() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("library"), store = try LibraryStore(root: root)
        let chapters = [Chapter(id: 0, title: "一", text: String(repeating: "灯塔 😀\u{0} 在海边。\n", count: 80)), Chapter(id: 1, title: "二", text: "她在山中。未读的结局。")]
        var book = try store.importBook(title: "故事", chapters: chapters)
        book.readThrough = .init(chapter: 1, offset: 5); try store.save(book)
        let recorder = EmbeddingRecorder()
        try await BookMemory.index(book: book, root: root, fingerprint: "m1", embed: { await recorder.encode($0) })
        let sent = await recorder.recorded()
        XCTAssertGreaterThan(sent.count, 2); XCTAssertFalse(sent.contains { $0.contains("结局") })
        for chapter in chapters {
            let chunks = BookMemory.chunks(bookID: book.id, chapter: chapter, scope: ReadingScope(through: book.readThrough))
            XCTAssertFalse(chunks.isEmpty)
            XCTAssertTrue(chunks.allSatisfy { $0.text.utf16.count <= 640 && $0.isValid(in: chapter, scope: ReadingScope(through: book.readThrough)) })
        }
        try await BookMemory.index(book: book, root: root, fingerprint: "m1", embed: { await recorder.encode($0) })
        let repeated = await recorder.recorded(); XCTAssertEqual(repeated, sent)
        let retrieved = try await BookMemory.retrieve(query: "灯塔的位置", books: [book], root: root, fingerprint: "m1", embed: { await recorder.encode($0) })
        let afterQuery = await recorder.recorded(); XCTAssertEqual(afterQuery, sent + ["灯塔的位置"])
        XCTAssertFalse(retrieved.isEmpty)
        let hits = try BookMemory.search(book: book, root: root, fingerprint: "m1", vector: [1, 0], limit: 2)
        XCTAssertEqual(hits.count, 2); XCTAssertTrue(hits.allSatisfy { $0.chapter == 0 })
        book.readThrough = .init(chapter: 0, offset: 8); try store.save(book)
        XCTAssertTrue(try BookMemory.search(book: book, root: root, fingerprint: "m1", vector: [0, 1]).isEmpty)
        try await BookMemory.index(book: book, root: root, fingerprint: "m1", embed: { await recorder.encode($0) })
        XCTAssertEqual(try BookMemory.search(book: book, root: root, fingerprint: "m1", vector: [1, 0]).first?.text, TextBoundary.prefix(chapters[0].text, end: 8))
        let zip = directory.appendingPathComponent("memory.zip")
        _ = try await BackupArchive.create(root: root, output: zip)
        let prepared = try await BackupArchive.prepare(zip, beside: root)
        try BackupArchive.activate(prepared, replacing: root)
        XCTAssertEqual(try BookMemory.search(book: book, root: root, fingerprint: "m1", vector: [1, 0]).count, 1)
        XCTAssertTrue(try BookMemory.search(book: book, root: root, fingerprint: "m2", vector: [1, 0]).isEmpty)
        let cleared = try store.clearBody(book)
        XCTAssertFalse(cleared.hasBody)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(book.id).appendingPathComponent("vectors.sqlite").path))
    }

    func testInterruptedIndexRetainsCheckpointsAndRevalidatesAfterRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let chapters = [Chapter(id: 0, title: "一", text: "灯塔。"), Chapter(id: 1, title: "二", text: "山川。")]
        var book = try store.importBook(title: "故事", chapters: chapters)
        book.readThrough = .init(chapter: 1, offset: 3); try store.save(book)
        do {
            try await BookMemory.index(book: book, root: root, fingerprint: "m", embed: { texts in
                if texts[0].contains("山川") { throw CancellationError() }
                return texts.map { _ in [1, 0] }
            })
            XCTFail("Interrupted request succeeded")
        } catch is CancellationError {} catch { XCTFail("Unexpected failure: \(error)") }
        let url = store.directory(book.id).appendingPathComponent("vectors.sqlite")
        let index = try BookVectorIndex(url: url, fingerprint: "m")
        XCTAssertTrue(try index.contains(book.chapters[0], through: 3))
        XCTAssertFalse(try index.contains(book.chapters[1], through: 3))
        let passage = SourcePassage(bookID: book.id, chapter: chapters[0], offset: 0, text: chapters[0].text)
        XCTAssertThrowsError(try index.replace(book.chapters[0], through: 3, passages: [passage, passage], vectors: [[1, 0], [1, 0]]))
        XCTAssertEqual(try index.count(), 1)
        XCTAssertThrowsError(try index.replace(book.chapters[0], through: 3, passages: [passage], vectors: [[1, 0, 0]]))
        let recorder = EmbeddingRecorder()
        try await BookMemory.index(book: book, root: root, fingerprint: "m", embed: { await recorder.encode($0) })
        let resumed = await recorder.recorded(); XCTAssertEqual(resumed, ["二\n山川。"])
        let snapshot = book
        do {
            try await BookMemory.index(book: snapshot, root: root, fingerprint: "new-model", embed: { texts in
                var changed = snapshot; changed.readThrough = .init(); try LibraryStore(root: root).save(changed)
                return texts.map { _ in [1, 0] }
            })
            XCTFail("Changed reading boundary was accepted")
        } catch {}
        XCTAssertEqual(try BookVectorIndex(url: url, fingerprint: "new-model").count(), 0)
        XCTAssertEqual(try BookVectorIndex(url: url).count(), 0)
    }
}
