import XCTest
@testable import MoReadCore

final class ShelfTests: XCTestCase {
    func testGroupCyclesDeletionTagMergeAndCollectionsKeepMembership() throws {
        let book = UUID(), second = UUID()
        var shelf = ShelfOrganization()
        let parent = ShelfGroup(name: "小说")
        let child = ShelfGroup(name: "奇幻", parentID: parent.id)
        try shelf.saveGroup(parent); try shelf.saveGroup(child)
        shelf.bookGroups[book] = child.id
        XCTAssertEqual(shelf.groupPath(child.id), "小说 / 奇幻")
        var cycle = parent; cycle.parentID = child.id
        XCTAssertThrowsError(try shelf.saveGroup(cycle))
        XCTAssertEqual(shelf.groups.first, parent)
        try shelf.deleteGroup(child.id)
        XCTAssertEqual(shelf.bookGroups[book], parent.id)
        let tag = ShelfTag(name: "喜欢"), target = ShelfTag(name: "收藏")
        XCTAssertEqual(ShelfOrganization.normalizedTag("  长篇\n  奇幻，冒险  "), "长篇 奇幻,冒险")
        try shelf.saveTag(tag); try shelf.saveTag(target)
        shelf.bookTags[book] = [tag.id, target.id]; shelf.bookTags[second] = [tag.id]
        shelf.deleteTag(tag.id, mergingInto: target.id)
        XCTAssertEqual(shelf.bookTags[book], [target.id]); XCTAssertEqual(shelf.bookTags[second], [target.id])
        let one = ShelfCollection(name: "第一套"), two = ShelfCollection(name: "第二套")
        try shelf.saveCollection(one); try shelf.saveCollection(two)
        shelf.setCollection(one.id, for: [book, second]); shelf.setCollection(two.id, for: [book])
        XCTAssertEqual(shelf.collections[0].bookIDs, [second]); XCTAssertEqual(shelf.collections[1].bookIDs, [book])
        shelf.prune(keeping: [book])
        XCTAssertNil(shelf.bookTags[second]); XCTAssertTrue(shelf.collections[0].bookIDs.isEmpty)
        XCTAssertNoThrow(try shelf.validate())
    }
    func testCombinedFiltersManualOrderingAndStorageRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        var first = try store.importBook(title: "灯塔", author: "作者", chapters: [Chapter(id: 0, title: "一", text: "正文")])
        let second = try store.importBook(title: "森林", chapters: [Chapter(id: 0, title: "一", text: "正文")])
        first.state = "在读"
        var shelf = ShelfOrganization()
        let tag = ShelfTag(name: "旅行"), other = ShelfTag(name: "长篇")
        try shelf.saveTag(tag); try shelf.saveTag(other)
        shelf.bookTags[first.id] = [tag.id, other.id]; shelf.bookTags[second.id] = [other.id]
        var filter = ShelfFilter(); filter.tags = [tag.id, other.id]; filter.matchAllTags = true
        XCTAssertEqual(shelf.filtered([first, second], query: "旅行", filter: filter).map(\.id), [first.id])
        filter.matchAllTags = false
        XCTAssertEqual(shelf.filtered([first, second], query: "", filter: filter).count, 2)
        filter.state = "在读"
        XCTAssertEqual(shelf.filtered([first, second], query: "", filter: filter).map(\.id), [first.id])
        shelf.move(first.id, before: second.id, among: [first, second])
        XCTAssertEqual(shelf.sorted([second, first], by: .manual).map(\.id), [first.id, second.id])
        try store.saveOrganization(shelf)
        XCTAssertEqual(try LibraryStore(root: root).organization(), shelf)
    }
}
