import XCTest
@testable import MoReadCore

final class LocalDictionaryTests: XCTestCase {
    private func fixture(_ name: String) throws -> URL { try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Dictionary")) }
    func testImportDuplicatesResourcesEnableDeleteAndRestore() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("library")
        _ = try LibraryStore(root: root)
        let library = LocalDictionaries(root: root)
        let imported = try await library.add(fixture("sample-v2.mdx"))
        XCTAssertFalse(imported.duplicate)
        let repeated = try await library.add(fixture("sample-v2.mdx"))
        XCTAssertTrue(repeated.duplicate); XCTAssertEqual(repeated.dictionary.id, imported.dictionary.id)
        let added = try await library.addResource(fixture("sample.mdd"), to: imported.dictionary.id)
        let duplicate = try await library.addResource(fixture("sample.mdd"), to: imported.dictionary.id)
        XCTAssertTrue(added); XCTAssertFalse(duplicate)
        let css = try await library.resource(imported.dictionary.id, path: "style.css")
        XCTAssertEqual(String(data: try XCTUnwrap(css), encoding: .utf8), "body{color:blue}")
        let matches = try await library.lookup("APPLE")
        XCTAssertEqual(matches.first?.html, "<b>apple</b> 苹果")
        try await library.setEnabled(imported.dictionary.id, false)
        let disabled = try await library.lookup("apple")
        XCTAssertTrue(disabled.isEmpty)
        let restarted = LocalDictionaries(root: root)
        let items = try await restarted.list()
        XCTAssertEqual(items.count, 1); XCTAssertFalse(items[0].enabled); XCTAssertEqual(items[0].resources.count, 1)
        let archive = temporary.appendingPathComponent("dictionary.zip")
        _ = try await BackupArchive.create(root: root, output: archive)
        try await library.remove(imported.dictionary.id)
        let empty = try await library.list(); XCTAssertTrue(empty.isEmpty)
        let prepared = try await BackupArchive.prepare(archive, beside: root)
        try BackupArchive.activate(prepared, replacing: root)
        let restored = LocalDictionaries(root: root)
        let restoredItems = try await restored.list(); XCTAssertEqual(restoredItems, items)
        try await restored.setEnabled(imported.dictionary.id, true)
        let restoredMatches = try await restored.lookup("books")
        XCTAssertFalse(restoredMatches.isEmpty)
        _ = try await restored.add(fixture("sample-classical.mdx"))
        let multiple = try await restored.lookup("apple")
        XCTAssertEqual(multiple.count, 2)
        XCTAssertEqual(Set(multiple.map(\.dictionaryID)).count, 2)
        XCTAssertTrue(multiple.contains { $0.html.contains("第二词典") })
        try Data("broken".utf8).write(to: root.appendingPathComponent("dictionaries/\(imported.dictionary.id)/main.mdx"))
        let corrupt = temporary.appendingPathComponent("corrupt.zip")
        _ = try await BackupArchive.create(root: root, output: corrupt)
        do { _ = try await BackupArchive.prepare(corrupt, beside: root); XCTFail("Corrupt dictionary restored") } catch { }
    }
    func testInvalidImportAndResourceDoNotPublishPartialFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LocalDictionaries(root: root)
        let bad = root.appendingPathComponent("bad.mdx")
        try Data("invalid".utf8).write(to: bad)
        do { _ = try await library.add(bad); XCTFail("Invalid file imported") } catch { }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("dictionaries").path).isEmpty)
        let item = try await library.add(fixture("sample-v1.mdx")).dictionary
        let invalidResource = root.appendingPathComponent("bad.mdd")
        try Data("invalid".utf8).write(to: invalidResource)
        do { _ = try await library.addResource(invalidResource, to: item.id); XCTFail("Invalid resource imported") } catch { }
        let contents = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("dictionaries/\(item.id)").path)
        XCTAssertEqual(Set(contents), ["main.mdx", "dictionary.json"])
        do { _ = try await library.lookup(String(repeating: "a", count: 81)); XCTFail("Oversized query accepted") } catch { }
    }
}
