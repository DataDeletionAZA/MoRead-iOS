import XCTest
@testable import MoReadCore

final class HybridRetrievalTests: XCTestCase {
    func testChineseTermsBM25FusionDistanceAndChapterDiversity() throws {
        let id = UUID()
        func passage(_ chapter: Int, _ text: String, offset: Int = 0) -> SourcePassage { .init(bookID: id, chapter: .init(id: chapter, title: "章", text: text), offset: offset, text: text) }
        let exact = passage(0, "秋宁找到祭司传承。"), generic = passage(1, "秋宁走进花园。"), unrelated = passage(2, "阳光落在窗台。")
        let terms = HybridRetrieval.tokens("秋宁 祭司传承 STAR-17")
        XCTAssertTrue(terms.contains("祭司传承")); XCTAssertTrue(terms.contains("秋宁")); XCTAssertTrue(terms.contains("star")); XCTAssertTrue(terms.contains("17"))
        let lexical = try HybridRetrieval.lexical([generic, unrelated, exact], query: "秋宁 祭司传承")
        XCTAssertEqual(lexical.first?.passage, exact); XCTAssertFalse(lexical.contains { $0.passage == unrelated })
        let fused = HybridRetrieval.fuse(vector: [.init(unrelated, distance: 1.4), .init(generic, distance: 0.4), .init(exact, distance: 1.2)], lexical: lexical, query: "秋宁 祭司传承")
        XCTAssertEqual(fused.first?.passage, exact); XCTAssertFalse(fused.contains { $0.passage == unrelated })
        let harbor = passage(0, "harbor boats harbor boats harbor boats."), garden = passage(1, "Birds sang in the garden."), lighthouse = passage(2, "At the harbor, the lighthouse beacon shone.")
        let words = try HybridRetrieval.lexical([harbor, garden, lighthouse], query: "lighthouse harbor")
        let combined = HybridRetrieval.fuse(vector: [.init(harbor, distance: 0.2), .init(garden, distance: 1.4), .init(lighthouse, distance: 0.5)], lexical: words, query: "lighthouse harbor")
        XCTAssertEqual(combined.first?.passage, lighthouse); XCTAssertFalse(combined.contains { $0.passage == garden })
        let short = SourcePassage(bookID: id, chapter: .init(id: 0, title: "一", text: exact.text), offset: 0, text: "秋宁")
        XCTAssertEqual(HybridRetrieval.fuse(vector: [.init(exact, distance: 0.3)], lexical: [.init(short, lexicalScore: 1)], query: "秋宁").count, 2)
        let repeated = (0..<12).map { RetrievalCandidate(passage($0 < 6 ? 0 : $0 - 5, "candidate \($0)", offset: $0 * 40), distance: 0.3) }
        let selected = HybridRetrieval.select(repeated, query: "unmatched query", topK: 8)
        XCTAssertEqual(selected.count, 8); XCTAssertEqual(selected.filter { $0.passage.chapter == 0 }.count, 2)
        XCTAssertTrue(HybridRetrieval.fuse(vector: [.init(unrelated, distance: .nan)], lexical: [], query: "窗台").isEmpty)
    }
    func testRerankPrecedesSelectionAndExpandedSourcesStayInsideScope() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let chapters = (0..<8).map { Chapter(id: $0, title: "Chapter \($0)", text: "signal clue \($0).") } + [Chapter(id: 8, title: "边界", text: "signal readable. secret ending")]
        var book = try store.importBook(title: "Signals", chapters: chapters); book.readThrough = .init(chapter: 8, offset: 16); try store.save(book)
        var context = try CompanionContextBuilder.build(query: "signal", books: [book], currentBook: nil, store: store, topK: 2)
        XCTAssertEqual(context.passages.count, 2); XCTAssertEqual(context.rerankPassages.count, 9)
        XCTAssertFalse(context.passages.contains { $0.chapter == 7 }); XCTAssertFalse(context.rerankPassages.contains { $0.text.contains("secret") })
        let order = Array(context.rerankPassages.reversed())
        try context.applyRanking(order, books: [book], store: store)
        XCTAssertEqual(context.passages.first?.chapter, order.first?.chapter); XCTAssertEqual(context.passages.first?.chapter, 7); XCTAssertFalse(context.text.contains("secret"))
        let narrowed = try CompanionContextBuilder.build(query: "signal", books: [book], currentBook: nil, store: store, firstChapter: 5, lastChapter: 6, chapterOrder: true)
        XCTAssertEqual(narrowed.passages.map(\.chapter), [5,6])
        XCTAssertEqual(try ReaderTools.searchOptions(["from_chapter": 6, "to_chapter": 9], book: book).first, 5)
        XCTAssertThrowsError(try ReaderTools.searchOptions(["from_chapter": true], book: book))
        var invalid = book; invalid.readThrough.chapter = Int.max
        XCTAssertThrowsError(try ReaderTools.searchOptions([:], book: invalid))
        let body = String(repeating: "海岸线很长。", count: 80) + "灯塔亮起。" + String(repeating: "潮汐上涨。", count: 180) + "不可泄漏的结局"
        let chapter = Chapter(id: 0, title: "长章", text: body)
        var longBook = try store.importBook(title: "海岸", chapters: [chapter]); longBook.readThrough = .init(chapter: 0, offset: body.utf16.count - 8); try store.save(longBook)
        let expanded = try CompanionContextBuilder.build(query: "灯塔", books: [longBook], currentBook: nil, store: store)
        XCTAssertTrue(expanded.passages.first?.text.contains("潮汐") == true)
        XCTAssertFalse(expanded.text.contains("不可泄漏的结局"))
        for source in expanded.passages { XCTAssertTrue(source.isValid(in: chapter, scope: ReadingScope(through: longBook.readThrough))) }
    }
    func testMissingChapterReportsPartialCoverageAndGlobalRecallDoesNotCreateIndex() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root), chapters = [Chapter(id: 0, title: "一", text: "灯塔远望"), Chapter(id: 1, title: "二", text: "灯塔仍在远方")]
        var book = try store.importBook(title: "灯塔", chapters: chapters); book.readThrough = .init(chapter: 1, offset: chapters[1].text.utf16.count); try store.save(book)
        let empty = try await BookMemory.recall(query: "灯塔", books: [book], root: root, fingerprint: "fixture", buildMissingIndex: false, embed: { _ in XCTFail("A catalog query must not create an index"); return [] })
        XCTAssertTrue(empty.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(book.id).appendingPathComponent("vectors.sqlite").path))
        try await BookMemory.index(book: book, root: root, fingerprint: "fixture", embed: { texts in texts.map { _ in [Float(1), 0] } })
        let recalled = try await BookMemory.recall(query: "灯塔", books: [book], root: root, fingerprint: "fixture", buildMissingIndex: false, firstChapter: 1, lastChapter: 1, embed: { texts in XCTAssertEqual(texts, ["灯塔"]); return [[1,0]] })
        XCTAssertEqual(recalled.map { $0.passage.chapter }, [1]); XCTAssertEqual(recalled.first?.distance, 0)
        try FileManager.default.removeItem(at: store.directory(book.id).appendingPathComponent("chapter-0.json"))
        let context = try CompanionContextBuilder.build(query: "灯塔", books: [book], currentBook: book.id, store: store)
        XCTAssertTrue(context.retrievalNotice?.contains("1 章读取失败") == true)
        XCTAssertTrue(context.text.contains("灯塔仍在远方")); XCTAssertEqual(context.passages.map(\.chapter), [1])
    }
}
