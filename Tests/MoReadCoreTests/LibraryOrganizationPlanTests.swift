import XCTest
@testable import MoReadCore

final class LibraryOrganizationPlanTests: XCTestCase {
    func testPreviewValidationAtomicChangesStaleProtectionAndReceipts() throws {
        let books = [Book(title: "海岸", chapters: [.init(id: 0, title: "一", text: "海")]), Book(title: "森林", chapters: [.init(id: 0, title: "一", text: "树")])]
        var shelf = ShelfOrganization()
        let old = ShelfTag(name: "旧标签"), shared = ShelfTag(name: "共读"), group = ShelfGroup(name: "小说")
        try shelf.saveTag(old); try shelf.saveTag(shared); try shelf.saveGroup(group)
        shelf.bookTags[books[0].id] = [old.id]
        let initial = shelf
        let rows: [[String: Any]] = [["book_id": books[0].id.uuidString, "add_tags": ["共读", "冒险", "冒险"], "remove_tags": ["旧标签"], "group_name": "小说"], ["book_id": books[1].id.uuidString, "add_tags": ["冒险"], "group_name": "旅途"]]
        let plan = try LibraryOrganizationPlan.preview(arguments: ["changes": rows], books: books, shelf: shelf)
        XCTAssertEqual(shelf, initial); XCTAssertEqual(plan.changes[0].addTags, ["共读", "冒险"])
        XCTAssertEqual(try LibraryOrganizationPlan.decode(plan.encoded()), plan)
        for row: [String: Any] in [["book_id": books[0].id.uuidString, "add_tags": ["Same"], "remove_tags": ["same"]], ["book_id": books[0].id.uuidString, "remove_tags": ["不存在"]], ["book_id": UUID().uuidString, "add_tags": ["标签"]], ["book_id": books[0].id.uuidString, "group_name": true], ["book_id": books[0].id.uuidString, "add_tags": ["标签\u{0000}"]]] {
            XCTAssertThrowsError(try LibraryOrganizationPlan.preview(arguments: ["changes": [row]], books: books, shelf: shelf))
        }
        XCTAssertThrowsError(try LibraryOrganizationPlan.preview(arguments: ["changes": [rows[0], rows[0]]], books: books, shelf: shelf))
        XCTAssertThrowsError(try LibraryOrganizationPlan.preview(arguments: ["changes": Array(repeating: rows[0], count: 21)], books: books, shelf: shelf))
        var changedBooks = books; changedBooks[1].title = "改名"
        XCTAssertThrowsError(try plan.resolve(apply: true, books: changedBooks, shelf: &shelf)); XCTAssertEqual(shelf, initial)
        var renamed = group; renamed.name = "另一个分类"; try shelf.saveGroup(renamed)
        let stale = shelf
        XCTAssertThrowsError(try plan.resolve(apply: true, books: books, shelf: &shelf)); XCTAssertEqual(shelf, stale)
        shelf = initial
        try plan.resolve(apply: true, books: books, shelf: &shelf)
        XCTAssertEqual(shelf.organizationDecisions?[plan.id], "applied")
        XCTAssertEqual(shelf.bookGroups[books[0].id], group.id)
        XCTAssertEqual(shelf.groups.first { $0.id == shelf.bookGroups[books[1].id] }?.name, "旅途")
        let adventure = try XCTUnwrap(shelf.tags.first { $0.name == "冒险" })
        XCTAssertEqual(Set(shelf.bookTags[books[0].id] ?? []), [shared.id, adventure.id]); XCTAssertEqual(shelf.bookTags[books[1].id], [adventure.id])
        let applied = shelf
        XCTAssertThrowsError(try plan.resolve(apply: true, books: books, shelf: &shelf)); XCTAssertEqual(shelf, applied)
        let cancelled = try LibraryOrganizationPlan.preview(arguments: ["changes": [["book_id": books[0].id.uuidString, "add_tags": ["待考虑"]]]], books: books, shelf: shelf)
        try cancelled.resolve(apply: false, books: [], shelf: &shelf)
        XCTAssertEqual(shelf.organizationDecisions?[cancelled.id], "cancelled"); XCTAssertEqual(shelf.tags, applied.tags); XCTAssertEqual(shelf.bookGroups, applied.bookGroups)
        XCTAssertThrowsError(try cancelled.resolve(apply: true, books: books, shelf: &shelf))
        XCTAssertTrue(try ReaderTools.specs(currentBook: nil, memory: false).contains { $0.name == "propose_library_organization" })
        XCTAssertFalse(try ReaderTools.specs(currentBook: books[0].id, memory: false).contains { $0.name == "propose_library_organization" })
        XCTAssertTrue(try ReaderTools.specs(currentBook: nil, memory: false, enabled: []).isEmpty)
    }
    func testPlansAndDecisionReceiptsSurviveBackupAndCatalogExposesCategories() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), root = directory.appendingPathComponent("library")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(root: root), companion = try CompanionStore(root: root)
        let book = try store.importBook(title: "灯塔", chapters: [.init(id: 0, title: "未来章名", text: "未来正文")])
        var shelf = ShelfOrganization()
        let plan = try LibraryOrganizationPlan.preview(arguments: ["changes": [["book_id": book.id.uuidString, "add_tags": ["海岸"], "group_name": "旅途"]]], books: [book], shelf: shelf)
        var conversation = Conversation(title: "整理", bookID: nil, characterID: UUID())
        var trace = ChatToolTrace(call: .init(id: "plan", name: "propose_library_organization", arguments: "{}"), title: "整理")
        trace.state = "succeeded"; trace.organizationPlan = plan
        var message = ChatMessage(role: "assistant", content: "请确认方案"); message.toolTrace = [trace]; conversation.messages = [message]
        try companion.save(conversation)
        XCTAssertTrue(LibraryOrganizationPlan.context(conversation: conversation, shelf: shelf).contains("等待用户确认"))
        try plan.resolve(apply: true, books: [book], shelf: &shelf); try store.saveOrganization(shelf)
        XCTAssertTrue(LibraryOrganizationPlan.context(conversation: conversation, shelf: shelf).contains("用户已确认应用"))
        let catalog = try ReaderTools.execute(.init(id: "catalog", name: "find_books", arguments: "{}"), currentBook: nil, books: [book], store: store)
        XCTAssertTrue(catalog.text.contains("海岸")); XCTAssertTrue(catalog.text.contains("旅途")); XCTAssertFalse(catalog.text.contains("未来"))
        var invalid = conversation; invalid.bookID = book.id
        XCTAssertThrowsError(try companion.save(invalid))
        let archive = directory.appendingPathComponent("backup.zip")
        _ = try await BackupArchive.create(root: root, output: archive)
        let prepared = try await BackupArchive.prepare(archive, beside: root)
        try BackupArchive.activate(prepared, replacing: root)
        XCTAssertEqual(try store.organization(), shelf); XCTAssertEqual(try companion.conversations(), [conversation])
        var restored = try store.organization()
        XCTAssertThrowsError(try plan.resolve(apply: true, books: [book], shelf: &restored))
    }
}
