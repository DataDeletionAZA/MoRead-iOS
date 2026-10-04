import XCTest
@testable import MoReadCore

final class ReadingReviewTests: XCTestCase {
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
