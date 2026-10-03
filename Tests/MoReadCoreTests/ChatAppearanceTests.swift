import XCTest
import ImageIO
import CoreGraphics
@testable import MoReadCore

final class ChatAppearanceTests: XCTestCase {
    func testLegacyCardsAndSanitizedAppearance() throws {
        XCTAssertTrue(ChatAppearance.darkText(onRGB: 0x00FF00))
        XCTAssertTrue(ChatAppearance.darkText(onRGB: 0xFFFFFF))
        XCTAssertFalse(ChatAppearance.darkText(onRGB: 0x0000FF))
        XCTAssertFalse(ChatAppearance.darkText(onRGB: 0))
        let card = CharacterCard()
        XCTAssertNil(try JSONDecoder().decode(CharacterCard.self, from: JSONEncoder().encode(card)).chatAppearance)
        let broken = Data(#"{"backgroundID":"bad","fontScale":100,"backgroundDim":-1,"bubble":"unknown","userRGB":-1}"#.utf8)
        let appearance = try JSONDecoder().decode(ChatAppearance.self, from: broken)
        XCTAssertNil(appearance.backgroundID); XCTAssertNil(appearance.userRGB)
        XCTAssertEqual(appearance.fontScale, 1.6); XCTAssertEqual(appearance.backgroundDim, 0); XCTAssertEqual(appearance.bubble, .rounded)
        var nonfinite = ChatAppearance(); nonfinite.fontScale = .nan; nonfinite.backgroundDim = .infinity
        XCTAssertEqual(nonfinite.validated(), ChatAppearance())
        var first = card; first.chatAppearance = appearance
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CompanionStore(root: root)
        try store.save(first); let second = CharacterCard(name: "另一位伙伴"); try store.save(second)
        let loaded = try store.characters()
        XCTAssertEqual(loaded.first { $0.id == first.id }?.chatAppearance, appearance)
        XCTAssertNil(loaded.first { $0.id == second.id }?.chatAppearance)
    }
    func testSharedImageBackupRemovalAndCorruption() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("library")
        _ = try LibraryStore(root: root)
        let context = try XCTUnwrap(CGContext(data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 40, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        let encoded = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(encoded, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        let images = ImageLibrary(root: root)
        let legacy = root.appendingPathComponent("reader-background.jpg")
        try (encoded as Data).write(to: legacy)
        let image = try XCTUnwrap(images.migrateLegacyBackground())
        XCTAssertEqual(image.name, "阅读背景")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertNil(try images.migrateLegacyBackground())
        XCTAssertEqual(try images.images().count, 1)
        XCTAssertThrowsError(try images.add(encoded as Data, name: "  "))
        XCTAssertEqual(try images.selectedBackground(), image.id)
        try images.rename(image, to: "窗边")
        XCTAssertEqual(try images.images().first?.name, "窗边")
        var card = CharacterCard(); var appearance = ChatAppearance()
        appearance.backgroundID = image.id; appearance.fontID = UUID(); appearance.bubble = .glass; appearance.fontScale = 1.4
        card.chatAppearance = appearance; try CompanionStore(root: root).save(card)
        XCTAssertThrowsError(try images.add(Data("broken".utf8), name: "损坏图片"))
        XCTAssertThrowsError(try images.selectBackground(UUID()))
        let backup = temporary.appendingPathComponent("images.zip")
        _ = try await BackupArchive.create(root: root, output: backup)
        try images.remove(image); XCTAssertTrue(try images.images().isEmpty)
        let prepared = try await BackupArchive.prepare(backup, beside: root)
        try BackupArchive.activate(prepared, replacing: root)
        XCTAssertEqual(try images.data(image.id), encoded as Data)
        XCTAssertEqual(try images.selectedBackground(), image.id)
        XCTAssertEqual(try CompanionStore(root: root).characters().first?.chatAppearance, appearance)
        try Data("broken".utf8).write(to: images.file(image.id))
        let corrupt = temporary.appendingPathComponent("corrupt.zip")
        _ = try await BackupArchive.create(root: root, output: corrupt)
        do { _ = try await BackupArchive.prepare(corrupt, beside: root); XCTFail("Invalid image accepted") } catch { XCTAssertTrue(error.localizedDescription.contains("图片")) }
        try BackupArchive.undo(previous: prepared.directory, replacing: root)
        XCTAssertTrue(try images.images().isEmpty)
        try images.selectBackground(nil); XCTAssertNil(try images.selectedBackground())
    }
}
