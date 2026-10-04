import XCTest
@testable import MoReadCore

final class ReviewCompositionTests: XCTestCase {
    func testMaterialsStayBoundToRecordsScopeAndSavedDraftBackup() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try LibraryStore(root: folder.appendingPathComponent("library"))
        let chapter = Chapter(id: 0, title: "书店", text: "灯光温暖。未知的秘密。")
        var book = try store.importBook(title: "夜色", chapters: [chapter])
        book.readThrough = .init(chapter: 0, offset: 5); try store.save(book)
        let personal = ReadingNote(title: "我的观察", content: "让我想起故乡。", book: book)
        let annotation = Annotation(passage: .init(bookID: book.id, chapter: chapter, offset: 0, text: "灯光温暖。"), note: "家的方向")
        var records = BookRecords(); records.notes = [personal]; records.annotations = [annotation]
        try store.saveRecords(records, for: book)
        let entries = ReadingReview.entries(books: [book], records: [book.id: records])
        let draft = try ReviewComposition(sources: entries, mode: .compose)
        var character = CharacterCard(name: "阿翎", description: "叫用户 {{user}}，我是 {{char}}。")
        character.personality = "温柔而严谨"
        let messages = try draft.messages(character: character, identity: .init(name: "读者"), instruction: "讨论家的意象")
        XCTAssertEqual(messages.map(\.role), ["system", "user"])
        XCTAssertTrue(messages[0].content.contains("叫用户 读者")); XCTAssertTrue(messages[0].content.contains("不杜撰引文"))
        XCTAssertTrue(messages[1].content.contains("[1]")); XCTAssertTrue(messages[1].content.contains("家的意象"))
        XCTAssertFalse(messages.map(\.content).joined().contains("未知的秘密"))
        let saved = try draft.note(title: "  夜色里的家  ", content: "我的感受和角色观点 [1]。", character: character, current: book, records: records)
        XCTAssertEqual(saved.title, "夜色里的家"); XCTAssertEqual(saved.characterID, character.id); XCTAssertTrue(saved.userEdited)
        XCTAssertTrue(saved.content.contains("素材出处")); XCTAssertTrue(saved.content.contains("> 灯光温暖。"))
        XCTAssertEqual(saved.sourceThrough, book.readThrough); XCTAssertEqual(saved.sourceRevisions, book.chapters.map(\.revision))
        records.notes?.append(saved); try store.saveRecords(records, for: book)
        XCTAssertEqual(try store.records(for: book).notes?.first, personal)
        try draft.validate(book: book, records: records)
        var changed = records; changed.notes?[0].content = "新的想法"
        XCTAssertThrowsError(try draft.validate(book: book, records: changed))
        changed = records; changed.annotations = []
        XCTAssertThrowsError(try draft.validate(book: book, records: changed))
        changed = records; changed.annotations.append(annotation)
        XCTAssertThrowsError(try draft.validate(book: book, records: changed))
        var earlier = book; earlier.readThrough = .init()
        XCTAssertThrowsError(try draft.validate(book: earlier, records: records))
        var revised = book; revised.chapters[0].revision = "different"
        XCTAssertThrowsError(try draft.validate(book: revised, records: records))
        var later = book; later.readThrough.offset = chapter.text.utf16.count
        XCTAssertNoThrow(try draft.validate(book: later, records: records))
        let archive = folder.appendingPathComponent("review.zip")
        _ = try await BackupArchive.create(root: store.root, output: archive)
        let restored = try await BackupArchive.prepare(archive, beside: store.root)
        defer { try? FileManager.default.removeItem(at: restored.directory) }
        XCTAssertEqual(try LibraryStore(root: restored.directory).records(for: book).notes, records.notes)
        XCTAssertThrowsError(try draft.note(title: "", content: "草稿", character: character, current: book, records: records))
        XCTAssertThrowsError(try draft.note(title: "草稿", content: String(repeating: "字", count: 32001), character: character, current: book, records: records))
    }
    func testWholeMaterialLimitsAndMixedBooks() throws {
        let book = Book(title: "书", chapters: [.init(id: 0, title: "章", text: "内容")])
        let entries = (0..<21).map { ReadingReviewEntry(book: book, content: .note(ReadingNote(title: "笔记\($0)", content: "感想", book: book))) }
        XCTAssertEqual(ReviewComposition.candidates(entries, bookID: book.id), Array(entries.prefix(20)))
        XCTAssertThrowsError(try ReviewComposition(sources: entries, mode: .comment))
        XCTAssertThrowsError(try ReviewComposition(sources: [], mode: .comment))
        XCTAssertThrowsError(try ReviewComposition(sources: [entries[0], entries[0]], mode: .comment))
        let other = Book(title: "另一本", chapters: [])
        let mixed = entries[0...0] + [ReadingReviewEntry(book: other, content: .note(ReadingNote(title: "另一本的笔记", content: "内容", book: other)))]
        XCTAssertThrowsError(try ReviewComposition(sources: Array(mixed), mode: .comment))
        let large = ReadingReviewEntry(book: book, content: .note(ReadingNote(title: "长笔记", content: String(repeating: "字", count: 24000), book: book)))
        XCTAssertTrue(ReviewComposition.candidates([large, entries[0]], bookID: book.id).isEmpty)
        XCTAssertThrowsError(try ReviewComposition(sources: [large], mode: .comment))
        let emojiBook = Book(title: String(repeating: "📚", count: 120), chapters: [])
        let emojiSource = ReadingReviewEntry(book: emojiBook, content: .note(ReadingNote(title: "笔记", content: "想法", book: emojiBook)))
        XCTAssertLessThanOrEqual(try ReviewComposition(sources: [emojiSource], mode: .compose).defaultTitle.utf16.count, 120)
        let draft = try ReviewComposition(sources: [entries[0]], mode: .comment)
        XCTAssertThrowsError(try draft.messages(character: .init(), identity: .init(name: "读者"), instruction: String(repeating: "字", count: 2001)))
    }
}
