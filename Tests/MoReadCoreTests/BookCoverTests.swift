import XCTest
import ImageIO
import CoreGraphics
@testable import MoReadCore

final class BookCoverTests: XCTestCase {
    func testCoverCropStorageBackupAndBodyCleanup() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("library"), store = try LibraryStore(root: root)
        var book = try store.importBook(title: "海岸", chapters: [.init(id: 0, title: "第一章", text: "潮起潮落。")])
        book.record(position: .init(offset: 2), visibleEnd: .init(offset: 4)); try store.save(book)
        let context = try XCTUnwrap(CGContext(data: nil, width: 20, height: 30, bitsPerComponent: 8, bytesPerRow: 80, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.7, blue: 0.5, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 20, height: 30))
        let data = NSMutableData(), image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        let jpeg = data as Data
        let imported = try store.importBook(title: "有封面的书", chapters: [.init(id: 0, title: "开篇", text: "书籍正文。")], cover: jpeg)
        XCTAssertEqual(try store.coverData(for: imported.id), jpeg)
        let count = try store.books().count
        XCTAssertThrowsError(try store.importBook(title: "损坏的封面", chapters: [.init(id: 0, title: "开篇", text: "正文。")], cover: Data("broken".utf8)))
        XCTAssertEqual(try store.books().count, count)
        XCTAssertNil(try store.coverData(for: book.id)); try store.saveCover(jpeg, for: book.id)
        XCTAssertEqual(try store.book(book.id), book)
        XCTAssertThrowsError(try store.saveCover(Data("broken".utf8), for: book.id))
        XCTAssertThrowsError(try store.saveCover(Data(repeating: 0, count: BookCoverImage.maximumBytes + 1), for: book.id))
        XCTAssertThrowsError(try store.saveCover(jpeg, for: UUID()))
        XCTAssertEqual(try store.coverData(for: book.id), jpeg)
        XCTAssertEqual(try BookCoverImage.cropRect(width: 600, height: 1200, y: 0), CGRect(x: 0, y: 0, width: 600, height: 900))
        XCTAssertEqual(try BookCoverImage.cropRect(width: 600, height: 1200, y: 1), CGRect(x: 0, y: 300, width: 600, height: 900))
        XCTAssertEqual(try BookCoverImage.cropRect(width: 1200, height: 900, x: 1), CGRect(x: 600, y: 0, width: 600, height: 900))
        XCTAssertThrowsError(try BookCoverImage.cropRect(width: 600, height: 900, x: .nan))
        XCTAssertThrowsError(try BookCoverImage.cropRect(width: 600, height: 900, y: 2))
        let backup = temporary.appendingPathComponent("covers.zip")
        _ = try await BackupArchive.create(root: root, output: backup)
        try store.saveCover(nil, for: book.id); XCTAssertNil(try store.coverData(for: book.id))
        let prepared = try await BackupArchive.prepare(backup, beside: root)
        try BackupArchive.activate(prepared, replacing: root)
        XCTAssertEqual(try store.coverData(for: book.id), jpeg)
        XCTAssertEqual(try store.book(book.id), book)
        let cleared = try store.clearBody(book)
        XCTAssertFalse(cleared.hasBody); XCTAssertEqual(try store.coverData(for: book.id), jpeg)
        try Data("corrupt".utf8).write(to: store.directory(book.id).appendingPathComponent("cover.jpg"))
        let corrupt = temporary.appendingPathComponent("corrupt.zip")
        _ = try await BackupArchive.create(root: root, output: corrupt)
        do { _ = try await BackupArchive.prepare(corrupt, beside: root); XCTFail("Corrupt cover was accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("封面")) }
    }
}
