import XCTest
import CryptoKit
import ReadiumZIPFoundation
@testable import MoReadCore

final class BackupTests: XCTestCase {
    func testVerifiedBackupRestoresAtomicallyAndKeepsPreviousLibrary() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = directory.appendingPathComponent("library")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try LibraryStore(root: root)
        let chapter = Chapter(id: 0, title: "第一章", text: "灯塔在海边。😀")
        let book = try library.importBook(title: "小说", chapters: [chapter])
        var records = BookRecords()
        records.annotations = [Annotation(passage: SourcePassage(bookID: book.id, chapter: chapter, offset: 0, text: "灯塔"), note: "记下这个地点")]
        try library.saveRecords(records, for: book)
        let companion = try CompanionStore(root: root)
        let conversation = Conversation(title: "伴读", bookID: book.id, characterID: UUID())
        try companion.save(conversation)
        var shelf = ShelfOrganization()
        let group = ShelfGroup(name: "小说")
        try shelf.saveGroup(group); shelf.bookGroups[book.id] = group.id
        try library.saveOrganization(shelf)
        let zip = directory.appendingPathComponent("backup.moread-ios.zip")
        _ = try await BackupArchive.create(root: root, output: zip)
        _ = try library.importBook(title: "后来导入的书", chapters: [chapter])
        let prepared = try await BackupArchive.prepare(zip, beside: root)
        XCTAssertEqual(prepared.bookCount, 1); XCTAssertEqual(prepared.conversationCount, 1)
        XCTAssertEqual(try library.books().count, 2)
        let previous = try BackupArchive.activate(prepared, replacing: root)
        XCTAssertEqual(try library.books().map(\.id), [book.id])
        XCTAssertEqual(try library.records(for: book).annotations, records.annotations)
        XCTAssertEqual(try CompanionStore(root: root).conversations(), [conversation])
        XCTAssertEqual(try library.organization(), shelf)
        XCTAssertEqual(try LibraryStore(root: previous).books().count, 2)
        try BackupArchive.undo(previous: previous, replacing: root)
        XCTAssertEqual(try library.books().count, 2)
    }

    func testCorruptionAndTraversalNeverChangeLiveLibrary() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = directory.appendingPathComponent("library")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try LibraryStore(root: root)
        let book = try library.importBook(title: "灯塔", chapters: [Chapter(id: 0, title: "一", text: "海边")])
        let zip = directory.appendingPathComponent("backup.zip")
        _ = try await BackupArchive.create(root: root, output: zip)
        let archive = try await Archive(url: zip, accessMode: .update)
        let path = "data/\(book.id.uuidString)/book.json"
        let found = try await archive.get(path)
        let entry = try XCTUnwrap(found)
        let original = try Data(contentsOf: library.directory(book.id).appendingPathComponent("book.json"))
        let changed = Data(String(decoding: original, as: UTF8.self).replacingOccurrences(of: "灯塔", with: "远方").utf8)
        try await archive.remove(entry)
        try await archive.addEntry(with: path, type: .file, uncompressedSize: Int64(changed.count)) { position, count in changed.subdata(in: Int(position)..<min(changed.count, Int(position) + count)) }
        do { _ = try await BackupArchive.prepare(zip, beside: root); XCTFail("Corrupt archive was accepted") } catch {}
        XCTAssertEqual(try library.books().first, book)

        let traversal = directory.appendingPathComponent("traversal.zip")
        let unsafe = try await Archive(url: traversal, accessMode: .create)
        let hash = SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined()
        let manifest = BackupManifest(files: [.init(path: "../escaped", bytes: 0, sha256: hash)])
        let data = try JSONEncoder().encode(manifest)
        try await unsafe.addEntry(with: "manifest.json", type: .file, uncompressedSize: Int64(data.count)) { position, count in data.subdata(in: Int(position)..<min(data.count, Int(position) + count)) }
        try await unsafe.addEntry(with: "data/../escaped", type: .file, uncompressedSize: 0) { _, _ in Data() }
        do { _ = try await BackupArchive.prepare(traversal, beside: root); XCTFail("Traversal archive was accepted") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("escaped").path))
        XCTAssertEqual(try library.books().first, book)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("MoRead-restore-") }, [])
    }
}
