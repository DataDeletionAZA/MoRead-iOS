import XCTest
@testable import MoReadCore

final class AnnotationDiscussionTests: XCTestCase {
    func testThreadMutationPersistenceAndStaleWrites() throws {
        let chapter = Chapter(id: 0, title: "灯塔", text: "海边亮起灯光。")
        var book = Book(title: "书店", chapters: [chapter]); book.readThrough = .init(offset: chapter.text.utf16.count)
        let annotation = Annotation(passage: .init(bookID: book.id, chapter: chapter, offset: 0, text: "海边"))
        var records = BookRecords(); records.annotations = [annotation]
        let reply = AnnotationReply(text: "  像回家的路。\n", author: "我", identity: .init(name: "Aza"))
        try AnnotationDiscussion.append(reply, to: annotation, book: book, records: &records)
        XCTAssertEqual(records.annotations[0].note, "像回家的路。"); XCTAssertNil(records.annotations[0].replies)
        XCTAssertThrowsError(try AnnotationDiscussion.append(reply, to: annotation, book: book, records: &records))
        let original = records.annotations[0]
        try AnnotationDiscussion.append(reply, to: original, book: book, records: &records)
        let current = records.annotations[0]
        XCTAssertEqual(current.replies, [reply])
        XCTAssertThrowsError(try AnnotationDiscussion.append(reply, to: current, book: book, records: &records))
        XCTAssertThrowsError(try AnnotationDiscussion.remove(reply, from: original, book: book, records: &records))
        let encoded = try JSONEncoder().encode(records)
        XCTAssertEqual(try JSONDecoder().decode(BookRecords.self, from: encoded).annotations, records.annotations)
        try ReadingReview.editAnnotation(.init(book: book, content: .annotation(current)), note: "新想法", style: "wave", book: book, records: &records)
        XCTAssertEqual(records.annotations[0].replies, [reply])
        try AnnotationDiscussion.remove(reply, from: records.annotations[0], book: book, records: &records)
        XCTAssertEqual(records.annotations[0].replies, [])
        try AnnotationDiscussion.append(reply, to: records.annotations[0], book: book, records: &records)
        try ReadingReview.delete(.init(book: book, content: .annotation(records.annotations[0])), book: book, records: &records)
        XCTAssertTrue(records.annotations.isEmpty)
        XCTAssertNoThrow(try JSONDecoder().decode(Annotation.self, from: JSONEncoder().encode(annotation)))
        var invalid = reply; invalid.text = String(repeating: "😀", count: 2501)
        XCTAssertThrowsError(try invalid.validate())
        var duplicate = annotation; duplicate.replies = [reply, reply]
        XCTAssertThrowsError(try AnnotationDiscussion.validateReplies(duplicate))
    }
    func testReadBoundaryCrossBookReplyScopeAndCurrentRecordValidation() throws {
        let text = String(repeating: "😀", count: 300) + "灯塔亮起。" + String(repeating: "雨", count: 600) + "未读秘密"
        let chapter = Chapter(id: 0, title: "第一章", text: text)
        var book = Book(title: "书店", chapters: [chapter]); book.readThrough = .init(offset: text.utf16.count - 4)
        var second = Book(title: "另一册", chapters: [chapter]); second.readThrough = .init(offset: 20)
        var annotation = Annotation(passage: .init(bookID: book.id, chapter: chapter, offset: 601, text: "灯塔亮起。"), note: "灯塔是谁点亮的？")
        var records = BookRecords(); records.annotations = [annotation]
        XCTAssertThrowsError(try AnnotationDiscussion(book: book, annotation: annotation, chapter: chapter, books: [book], records: records))
        annotation.passage = .init(bookID: book.id, chapter: chapter, offset: 600, text: "灯塔亮起。")
        var role = AnnotationReply(text: "另一册读过的灯塔", author: "阿翎"); role.characterID = UUID()
        role.scopes = [.init(id: second.id, through: second.readThrough, revision: MemoryBookScope.fingerprint(second.chapters.map(\.revision)))]
        var future = role; future.id = UUID(); future.text = "未来回复"; future.scopes = [.init(id: second.id, through: .init(offset: 100), revision: role.scopes[0].revision)]
        annotation.replies = [role, future]; records.annotations = [annotation]
        let snapshot = try AnnotationDiscussion(book: book, annotation: annotation, chapter: chapter, books: [book, second], records: records)
        XCTAssertEqual(snapshot.replies, [role]); XCTAssertEqual(snapshot.scopes.count, 2)
        XCTAssertEqual(snapshot.neighborhood, String(repeating: "😀", count: 250) + "灯塔亮起。" + String(repeating: "雨", count: 500))
        let messages = snapshot.messages(character: .init(name: "阿翎"), identity: .init(name: "Aza"))
        XCTAssertTrue(messages[0].content.contains("Aza")); XCTAssertTrue(messages[1].content.contains(role.text))
        XCTAssertFalse(messages[1].content.contains("未来回复")); XCTAssertFalse(messages[1].content.contains("未读秘密"))
        book.readThrough = .init(offset: 603)
        XCTAssertThrowsError(try snapshot.validate(book: book, records: records, books: [book, second]))
        book = snapshot.book; second.readThrough = .init()
        XCTAssertThrowsError(try snapshot.validate(book: book, records: records, books: [book, second])); XCTAssertFalse(role.visible(in: [book, second]))
        records.annotations[0].note = "已被修改"
        XCTAssertThrowsError(try snapshot.validate(book: book, records: records, books: [book, second]))
        role.scopes = []; XCTAssertFalse(role.visible(in: [book])); XCTAssertThrowsError(try role.validate())
        annotation.replies = nil; records.annotations = [annotation]; book.readThrough = .init(offset: 605)
        let clipped = try AnnotationDiscussion(book: book, annotation: annotation, chapter: chapter, books: [book], records: records)
        XCTAssertTrue(clipped.neighborhood.hasSuffix("灯塔亮起。")); XCTAssertFalse(clipped.neighborhood.contains("雨"))
    }
    func testExportFiltersHiddenRoleRepliesAndKeepsConversationsSeparate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(root: directory), chapter = Chapter(id: 0, title: "第一章", text: "海边灯塔")
        var book = try store.importBook(title: "书店", chapters: [chapter]); book.readThrough = .init(offset: 4); try store.save(book)
        var annotation = Annotation(passage: .init(bookID: book.id, chapter: chapter, offset: 0, text: "海边"), note: "开篇")
        let mine = AnnotationReply(text: "期待以后", author: "我")
        var role = AnnotationReply(text: "读过的灯塔", author: "阿翎"); role.characterID = UUID()
        role.scopes = [.init(id: book.id, through: book.readThrough, revision: MemoryBookScope.fingerprint(book.chapters.map(\.revision)))]
        annotation.replies = [mine, role]; try store.modifyRecords(for: book) { $0.annotations = [annotation] }
        XCTAssertTrue(try store.notesMarkdown(for: book).contains(role.text))
        book.readThrough = .init(offset: 2); try store.save(book)
        let export = try store.notesMarkdown(for: book)
        XCTAssertFalse(export.contains(role.text)); XCTAssertTrue(export.contains(mine.text))
        XCTAssertTrue(try CompanionStore(root: directory).conversations().isEmpty)
    }
    func testBackupRestoresRoleThreadAndRejectsMalformedReplies() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("library"), store = try LibraryStore(root: root)
        let chapter = Chapter(id: 0, title: "第一章", text: "海边灯塔")
        var book = try store.importBook(title: "书店", chapters: [chapter]); book.readThrough = .init(offset: 4); try store.save(book)
        var annotation = Annotation(passage: .init(bookID: book.id, chapter: chapter, offset: 0, text: "海边"), note: "开篇")
        var role = AnnotationReply(text: "读过的灯塔", author: "阿翎"); role.characterID = UUID()
        role.scopes = [.init(id: book.id, through: book.readThrough, revision: MemoryBookScope.fingerprint(book.chapters.map(\.revision)))]
        annotation.replies = [role]; try store.modifyRecords(for: book) { $0.annotations = [annotation] }
        let zip = directory.appendingPathComponent("thread.zip")
        _ = try await BackupArchive.create(root: root, output: zip)
        let prepared = try await BackupArchive.prepare(zip, beside: root)
        XCTAssertEqual(try LibraryStore(root: prepared.directory).records(for: book).annotations, [annotation])
        try store.modifyRecords(for: book) { $0.annotations[0].replies = [role, role] }
        let malformed = directory.appendingPathComponent("malformed.zip")
        _ = try await BackupArchive.create(root: root, output: malformed)
        do { _ = try await BackupArchive.prepare(malformed, beside: root); XCTFail("Duplicate replies accepted") } catch {}
        XCTAssertEqual(try store.records(for: book).annotations[0].replies?.count, 2)
    }
    func testDiscussionToolsRejectWritesAndStopAfterFiveRounds() async throws {
        let specs = try ReaderTools.specs(currentBook: UUID(), memory: true, enabled: Array(AnnotationDiscussion.readTools))
        XCTAssertTrue(Set(specs.map(\.name)).isSubset(of: AnnotationDiscussion.readTools))
        var executed: [String] = [], rounds = 0
        do {
            try await ChatToolLoop.run(tools: specs, maximumRounds: 5, stream: { exchanges in
                rounds += 1
                if let previous = exchanges.last { XCTAssertTrue(previous.results[0].failed) }
                return .init(text: "", calls: [.init(id: "write", name: "save_note", arguments: "{}"), .init(id: "read", name: "list_chapters", arguments: "{}")], replay: Data("{}".utf8))
            }, execute: { call in executed.append(call.name); return "第一章" }, validate: {}, report: { _ in })
            XCTFail("Expected bounded tool loop")
        } catch { XCTAssertEqual(rounds, 5); XCTAssertEqual(executed, Array(repeating: "list_chapters", count: 5)) }
    }
}
