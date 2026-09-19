import XCTest
@testable import MoReadCore

final class FontLibraryTests: XCTestCase {
    func testFontImportRenameBackupAndInvalidFiles() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("library")
        _ = try LibraryStore(root: root)
        let library = FontLibrary(root: root)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("App/Fonts/NotoSerifSC.ttf")
        let imported = try library.add(source)
        XCTAssertTrue(imported.name.contains("Noto"))
        XCTAssertEqual(try Data(contentsOf: library.file(imported)), try Data(contentsOf: source))
        try library.rename(imported, to: "  阅读字体  ")
        var renamed = imported; renamed.name = "阅读字体"
        XCTAssertEqual(try library.fonts(), [renamed])
        let invalid = temporary.appendingPathComponent("broken.otf")
        try Data("not a font".utf8).write(to: invalid)
        XCTAssertThrowsError(try library.add(invalid))
        let handle = try FileHandle(forWritingTo: invalid)
        try handle.truncate(atOffset: UInt64(FontLibrary.maximumBytes + 1)); try handle.close()
        XCTAssertThrowsError(try library.add(invalid))
        XCTAssertEqual(try library.fonts(), [renamed])
        let backup = temporary.appendingPathComponent("fonts.zip")
        _ = try await BackupArchive.create(root: root, output: backup)
        try library.remove(renamed)
        XCTAssertTrue(try library.fonts().isEmpty)
        let prepared = try await BackupArchive.prepare(backup, beside: root)
        try BackupArchive.activate(prepared, replacing: root)
        XCTAssertEqual(try library.fonts(), [renamed])
        try Data("broken font".utf8).write(to: library.file(renamed))
        let corrupt = temporary.appendingPathComponent("corrupt.zip")
        _ = try await BackupArchive.create(root: root, output: corrupt)
        do { _ = try await BackupArchive.prepare(corrupt, beside: root); XCTFail("Invalid font was accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("字体")) }
        try BackupArchive.undo(previous: prepared.directory, replacing: root)
        XCTAssertTrue(try library.fonts().isEmpty)
    }
}
