import XCTest
@testable import MoReadCore

final class ReadingReviewTests: XCTestCase {
    func testEditingAndDeletingRequireCurrentRecordAndPreserveOtherData() throws {
        let chapter = Chapter(id: 0, title: "灯塔", text: "灯塔亮了。")
        var book = Book(title: "书店", chapters: [chapter]); book.readThrough = .init(chapter: 0, offset: chapter.text.utf16.count)
        var annotation = Annotation(passage: .init(bookID: book.id, chapter: chapter, offset: 0, text: chapter.text), note: "旧想法")
        annotation.characterID = UUID(); annotation.characterName = "林遥"; annotation.sourceThrough = book.readThrough
        annotation.generationKey = "tool:sample"
        let note = ReadingNote(title: "随记", content: "雨停了。", book: book)
        var records = BookRecords(); records.annotations = [annotation]; records.notes = [note]
        records.bookmarks = [.init(position: .init(), label: "灯塔")]; records.readingSeconds = ["2026-10-04": 60]
        let original = ReadingReviewEntry(book: book, content: .annotation(annotation))
        XCTAssertThrowsError(try ReadingReview.editAnnotation(original, note: "new", style: "unknown", book: book, records: &records))
        XCTAssertThrowsError(try ReadingReview.editAnnotation(original, note: String(repeating: "x", count: 50_001), style: "wave", book: book, records: &records))
        XCTAssertEqual(records.annotations, [annotation])
        try ReadingReview.editAnnotation(original, note: " 新的想法 \n", style: "wave", book: book, records: &records)
        var edited = annotation; edited.note = "新的想法"; edited.style = "wave"
        XCTAssertEqual(records.annotations, [edited]); XCTAssertEqual(records.notes, [note])
        XCTAssertThrowsError(try ReadingReview.editAnnotation(original, note: "过期修改", style: "underline", book: book, records: &records))
        XCTAssertThrowsError(try ReadingReview.delete(original, book: book, records: &records))
        let current = ReadingReviewEntry(book: book, content: .annotation(edited))
        var rewound = book; rewound.readThrough = .init()
        XCTAssertThrowsError(try ReadingReview.delete(current, book: rewound, records: &records))
        var another = book; another.id = UUID()
        XCTAssertThrowsError(try ReadingReview.delete(current, book: another, records: &records))
        try ReadingReview.delete(current, book: book, records: &records)
        XCTAssertTrue(records.annotations.isEmpty); XCTAssertEqual(records.notes, [note])
        XCTAssertThrowsError(try ReadingReview.delete(current, book: book, records: &records))
        book.bodyCleared = true; book.removed = true
        try ReadingReview.delete(.init(book: book, content: .note(note)), book: book, records: &records)
        XCTAssertTrue(records.notes!.isEmpty); XCTAssertEqual(records.bookmarks.count, 1); XCTAssertEqual(records.readingSeconds["2026-10-04"], 60)
    }
    func testReviewScopeFilteringRetainedRecordsAndExport() {
        let chapter = Chapter(id: 0, title: "灯塔", text: "灯塔很亮。未来的秘密。")
        var book = Book(title: "海边书店", author: "林间", chapters: [chapter])
        book.readThrough = .init(chapter: 0, offset: 5)
        let role = UUID()
        var mine = ReadingNote(title: "手写笔记", content: "想念故乡", book: book)
        mine.updatedAt = Date(timeIntervalSince1970: 1)
        var note = ReadingNote(title: "角色笔记", content: "灯塔很亮", book: book)
        note.characterID = role; note.characterName = "阿翎"; note.updatedAt = Date(timeIntervalSince1970: 2)
        var future = note; future.id = UUID(); future.content = "隐藏的秘密"; future.sourceThrough.offset = chapter.text.utf16.count
        var outdated = note; outdated.id = UUID(); outdated.sourceRevisions = ["old"]
        var annotation = Annotation(passage: .init(bookID: book.id, chapter: chapter, offset: 0, text: "灯塔很亮。"), note: "温暖的灯光")
        annotation.characterID = role; annotation.characterName = "阿翎"; annotation.sourceThrough = book.readThrough
        annotation.createdAt = Date(timeIntervalSince1970: 3)
        var missingScope = annotation; missingScope.id = UUID(); missingScope.sourceThrough = nil
        var pastScope = annotation; pastScope.id = UUID(); pastScope.sourceThrough?.offset = -1
        var wrongBook = annotation; wrongBook.id = UUID(); wrongBook.passage.bookID = UUID()
        var records = BookRecords(); records.notes = [mine, note, future, outdated]
        records.annotations = [annotation, missingScope, pastScope, wrongBook]
        var secondBook = Book(title: "另一座书店", chapters: [chapter])
        secondBook.bodyCleared = true; secondBook.removed = true
        var personal = annotation; personal.characterID = nil; personal.passage.bookID = secondBook.id
        var secondRecords = BookRecords(); secondRecords.annotations = [personal]
        let all = ReadingReview.entries(books: [book, secondBook], records: [book.id: records, secondBook.id: secondRecords])
        XCTAssertEqual(all.count, 4)
        XCTAssertEqual(Set(all.map(\.id)).count, 4)
        XCTAssertNil(all.first { $0.book.id == secondBook.id }?.passage)
        XCTAssertFalse(ReadingReview.markdown(all).contains("隐藏的秘密"))
        var filter = ReadingReviewFilter()
        filter.bookIDs = [book.id]; filter.source = .companion; filter.characterID = role
        XCTAssertEqual(filter.apply(to: all).count, 2)
        filter.query = "林间 阿翎 温暖"
        XCTAssertEqual(filter.apply(to: all).map(\.body), ["温暖的灯光"])
        filter.query = ""; filter.kind = .note
        XCTAssertEqual(filter.apply(to: all).map(\.title), ["角色笔记"])
        filter.source = .mine
        XCTAssertEqual(filter.apply(to: all).map(\.title), ["手写笔记"])
        filter.source = .all; filter.kind = .all; filter.oldestFirst = true
        XCTAssertEqual(filter.apply(to: all).map(\.body), ["想念故乡", "灯塔很亮", "温暖的灯光"])
        let export = ReadingReview.markdown(filter.apply(to: all))
        XCTAssertTrue(export.contains("> 灯塔很亮。")); XCTAssertTrue(export.contains("海边书店")); XCTAssertFalse(export.contains("另一座书店"))
        book.readThrough = .init()
        XCTAssertEqual(ReadingReview.entries(books: [book], records: [book.id: records]).map(\.title), ["手写笔记"])
        book.readThrough = .init(chapter: 0, offset: 5); book.chapters[0].revision = "changed"
        XCTAssertEqual(ReadingReview.entries(books: [book], records: [book.id: records]).map(\.title), ["手写笔记"])
        XCTAssertTrue(ReadingReview.entries(books: [], records: [book.id: records]).isEmpty)
    }
}
