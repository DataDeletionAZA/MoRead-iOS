import XCTest
@testable import MoReadCore

final class ReaderWritingTests: XCTestCase {
    private func call(_ name: String, _ args: [String: Any]) throws -> ChatToolCall {
        .init(id: UUID().uuidString, name: name, arguments: String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self))
    }
    func testNotesOwnershipRollingSummaryScopeAndBackup() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), root = folder.appendingPathComponent("library")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try LibraryStore(root: root), chapters = [Chapter(id: 0, title: "一", text: "灯塔很亮。"), Chapter(id: 1, title: "二", text: "还未读到的后文")]
        var book = try store.importBook(title: "灯塔", chapters: chapters); book.readThrough = .init(chapter: 0, offset: chapters[0].text.utf16.count); try store.save(book)
        let card = CharacterCard(name: "阿翎"), other = CharacterCard(name: "另一位"), conversation = UUID()
        var records = BookRecords()
        func write(_ name: String, _ args: [String: Any], key: String = UUID().uuidString, as author: CharacterCard? = nil) throws -> ReadingNote {
            try ReaderTools.writingNote(call(name, args), book: book, records: records, character: author ?? card, conversationID: conversation, mutationKey: key)
        }
        let first = try write("write_note", ["title": "灯塔笔记", "content_md": "**灯塔**很亮。"], key: "first")
        records.notes = [first]
        XCTAssertEqual(try write("write_note", ["title": "重复", "content_md": "重复"], key: "first").id, first.id)
        XCTAssertThrowsError(try write("write_note", ["note_id": first.id.uuidString, "content_md": "改写"], as: other))
        var protected = first; protected.userEdited = true; records.notes = [protected]
        XCTAssertThrowsError(try write("write_note", ["note_id": first.id.uuidString, "content_md": "改写"]))
        var handwritten = first; handwritten.characterID = nil; records.notes = [handwritten]
        XCTAssertThrowsError(try write("write_note", ["note_id": first.id.uuidString, "content_md": "改写"]))
        records.notes = [first]
        let summary = try write("save_plot_summary", ["content_md": "抵达灯塔。"]); records.notes?.append(summary)
        let updated = try write("save_plot_summary", ["content_md": "抵达灯塔，注意到灯光。"])
        XCTAssertEqual(updated.id, summary.id); XCTAssertEqual(updated.toChapter, 1)
        XCTAssertNotEqual(try write("save_plot_summary", ["content_md": "新梗概", "as_new": true]).id, summary.id)
        XCTAssertThrowsError(try write("save_plot_summary", ["content_md": "未来剧情", "to_chapter": 2]))
        XCTAssertThrowsError(try write("save_plot_summary", ["content_md": "剧情", "as_new": 1]))
        XCTAssertThrowsError(try write("write_note", ["note_id": summary.id.uuidString, "content_md": "错误类型"]))
        records.notes = [first, updated]
        try store.saveRecords(records, for: book)
        try store.modifyRecords(for: book) { $0.bookmarks.append(.init(position: .init(), label: "书签")) }
        XCTAssertEqual(try store.records(for: book).notes?.count, 2)
        XCTAssertTrue(try store.notesMarkdown(for: book).contains("注意到灯光"))
        XCTAssertTrue(try ReaderTools.readNotes(arguments: ["kind": "plot_summary"], book: book, records: records).contains(updated.id.uuidString))
        XCTAssertEqual(try LibraryStore(root: root).records(for: book).notes, records.notes)
        let archive = folder.appendingPathComponent("notes.zip")
        _ = try await BackupArchive.create(root: root, output: archive)
        let restored = try await BackupArchive.prepare(archive, beside: root)
        defer { try? FileManager.default.removeItem(at: restored.directory) }
        XCTAssertEqual(try LibraryStore(root: restored.directory).records(for: book).notes, records.notes)
        book.readThrough = .init()
        XCTAssertFalse(first.visible(in: book))
        XCTAssertThrowsError(try ReaderTools.readNotes(arguments: ["note_id": first.id.uuidString], book: book, records: records))
        XCTAssertThrowsError(try write("write_note", ["note_id": first.id.uuidString, "content_md": "更早进度"] ))
        XCTAssertFalse(try ReaderTools.specs(currentBook: nil, memory: false).contains { ReaderTools.writing.contains($0.name) })
    }
    func testExactAnnotationsRejectAmbiguityForgedSourcesAndUnreadText() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let chapters = [Chapter(id: 0, title: "一", text: "灯塔亮起。🌙灯塔亮起。"), Chapter(id: 1, title: "二", text: "以后才知道的秘密")]
        var book = try store.importBook(title: "灯塔", chapters: chapters); book.readThrough = .init(chapter: 0, offset: chapters[0].text.utf16.count); try store.save(book)
        let card = CharacterCard(name: "阿翎"), source = SourcePassage(bookID: book.id, chapter: chapters[0], offset: 7, text: "灯塔亮起。")
        func annotate(_ args: [String: Any], sources: [SourcePassage] = []) throws -> Annotation { try ReaderTools.writingAnnotation(call("add_annotation", args), book: book, sources: sources, character: card, store: store, mutationKey: "tool:fixture") }
        XCTAssertThrowsError(try annotate(["quote": "灯塔亮起。", "comment": "重复引文"]))
        let annotation = try annotate(["quote": source.text, "comment": "注意灯光", "source_ref": source.id, "style": "wavy"], sources: [source])
        XCTAssertEqual(annotation.passage.offset, 7); XCTAssertEqual(annotation.style, "wave"); XCTAssertEqual(annotation.characterID, card.id)
        XCTAssertThrowsError(try annotate(["quote": "秘密", "comment": "未读内容"]))
        XCTAssertThrowsError(try annotate(["quote": source.text, "comment": "伪造来源", "source_ref": "unknown"], sources: [source]))
        XCTAssertThrowsError(try annotate(["quote": source.text, "comment": "错误章节", "source_ref": source.id, "chapter_number": 2], sources: [source]))
        var forged = source; forged.text = "编造的原文"
        XCTAssertThrowsError(try annotate(["quote": forged.text, "comment": "错误", "source_ref": forged.id], sources: [forged]))
        let original = book; book.readThrough = .init(); try store.save(book)
        XCTAssertThrowsError(try ReaderTools.writingAnnotation(call("add_annotation", ["quote": source.text, "comment": "范围退回", "source_ref": source.id]), book: original, sources: [source], character: card, store: store, mutationKey: "stale"))
    }
    func testLongNotePaginationAndTraceFailureStopsExecution() async throws {
        let chapter = Chapter(id: 0, title: "一", text: "已读")
        var book = Book(title: "书", chapters: [chapter]); book.readThrough = .init(chapter: 0, offset: 2)
        let card = CharacterCard(name: "阿翎")
        let request = try call("write_note", ["title": "长笔记", "content_md": String(repeating: "汉", count: 50000)])
        let note = try ReaderTools.writingNote(request, book: book, records: .init(), character: card, conversationID: UUID(), mutationKey: "long")
        var records = BookRecords(); records.notes = [note]
        let text = try ReaderTools.readNotes(arguments: ["note_id": note.id.uuidString, "start_char": 1000, "max_chars": 1000], book: book, records: records)
        XCTAssertTrue(text.contains("start_char=2000")); XCTAssertLessThan(text.utf16.count, 1300)
        XCTAssertThrowsError(try ReaderTools.readNotes(arguments: ["note_id": note.id.uuidString, "start_char": true], book: book, records: records))
        let tools = try ReaderTools.specs(currentBook: book.id, memory: false)
        var executed = false
        do {
            try await ChatToolLoop.run(tools: tools, stream: { _ in .init(text: "", calls: [request], replay: Data("{}".utf8)) }, execute: { _ in executed = true; return "saved" }, validate: {}, report: { _ in throw MoReadError.invalid("storage unavailable") })
            XCTFail("Expected trace failure")
        } catch { XCTAssertFalse(executed) }
    }
}
