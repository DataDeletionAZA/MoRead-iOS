import XCTest
@testable import MoReadCore

final class ReviewCardTests: XCTestCase {
    func testTemplateEditingBackupAndCorruptionPreserveLibrary() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("library"), store = try LibraryStore(root: root)
        _ = try store.importBook(title: "灯塔", chapters: [.init(id: 0, title: "开篇", text: "雨后。")])
        let library = ReviewCardLibrary(root: root)
        XCTAssertEqual(try library.templates(), [])
        XCTAssertThrowsError(try library.save(ReviewCardTemplate.presets[0]))
        var template = ReviewCardTemplate.presets[2]; template.id = UUID(); template.name = "夜读"
        template.customFontID = UUID(); template.backgroundImageID = UUID(); template.gradientEnd = 0x112233
        template.css = "color: linear-gradient(45deg, #c80, #08c); margin-top: 1em;"
        template.italic = true; template.borderWidth = 3; template.cornerRadius = 22
        try library.save(template)
        template.name = "我的夜读"; try library.save(template)
        XCTAssertEqual(try library.templates(), [template])
        let archive = temporary.appendingPathComponent("cards.zip")
        _ = try await BackupArchive.create(root: root, output: archive)
        try library.remove(template.id); XCTAssertTrue(try library.templates().isEmpty)
        let restored = try await BackupArchive.prepare(archive, beside: root)
        try BackupArchive.activate(restored, replacing: root)
        XCTAssertEqual(try library.templates(), [template])
        var invalid = template; invalid.padding = 1000
        XCTAssertThrowsError(try library.save(invalid)); XCTAssertEqual(try library.templates(), [template])
        invalid = template; invalid.fontSize = .nan; XCTAssertThrowsError(try invalid.validate())
        invalid = template; invalid.foreground = -1; XCTAssertThrowsError(try invalid.validate())
        let file = root.appendingPathComponent("review-card-templates.json")
        try JSONEncoder().encode([template, template]).write(to: file)
        XCTAssertThrowsError(try library.templates())
        let corrupt = temporary.appendingPathComponent("corrupt.zip")
        _ = try await BackupArchive.create(root: root, output: corrupt)
        do { _ = try await BackupArchive.prepare(corrupt, beside: root); XCTFail("Duplicate templates accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("模板")) }
        XCTAssertEqual(try store.books().count, 1)
    }
}
