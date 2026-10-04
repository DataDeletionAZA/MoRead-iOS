import XCTest
@testable import MoReadCore

final class VoiceLibraryTests: XCTestCase {
    func testAndroidImportAtomicMergeEditingAndExport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VoiceLibrary(root: root)
        let android = Data(#"[{"voiceId":"Kore","displayName":" 坚定声音 ","providerHint":"GEMINI","tags":"坚定，旁白,坚定","gender":"FEMALE","pinned":true,"sortOrder":2,"extraJson":"{}"}]"#.utf8)
        XCTAssertEqual(try store.importJSON(android), 1)
        var saved = try XCTUnwrap(store.voices().first)
        XCTAssertEqual(saved.tags, "坚定,旁白"); XCTAssertEqual(saved.displayName, "坚定声音")
        saved.displayName = "夜读"; try store.save(saved)
        XCTAssertEqual(try store.importJSON(android), 0); XCTAssertEqual(try store.voices(), [saved])
        XCTAssertEqual(try store.merge(VoiceLibrary.geminiPresets), 29)
        XCTAssertEqual(try store.merge(VoiceLibrary.geminiPresets), 0)
        XCTAssertEqual(try store.voices().first, saved)
        let before = try store.voices()
        XCTAssertThrowsError(try store.merge([SavedVoice(voiceId: "new", displayName: "新声音"), SavedVoice()]))
        XCTAssertEqual(try store.voices(), before)
        var duplicate = saved; duplicate.id = UUID(); XCTAssertThrowsError(try store.save(duplicate))
        let exported = try store.exportJSON()
        XCTAssertFalse(String(decoding: exported, as: UTF8.self).contains(saved.id.uuidString))
        let second = root.appendingPathComponent("second"); try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let copy = VoiceLibrary(root: second); XCTAssertEqual(try copy.importJSON(exported), 30)
        XCTAssertEqual(try copy.voices().map(\.displayName), before.map(\.displayName))
        try store.remove(saved.id); XCTAssertFalse(try store.voices().contains { $0.id == saved.id })
    }
    func testSelectionPreservesProviderAndSettings() throws {
        var settings = CloudSpeechSettings(); settings.preset(.gemini)
        settings.enabled = true; settings.baseURL = "https://example.com/v1beta"; settings.instructions = "温柔讲故事"; settings.speed = 1.3
        let voice = SavedVoice(voiceId: "Kore", displayName: "坚定", providerHint: "GEMINI")
        var expected = settings; expected.voice = "Kore"
        XCTAssertEqual(try voice.applying(to: settings), expected)
        XCTAssertThrowsError(try VoiceLibrary.miniMaxPresets[0].applying(to: settings))
        settings.preset(.gmi); XCTAssertEqual(try VoiceLibrary.miniMaxPresets[0].applying(to: settings).voice, "male-qn-qingse")
        settings.preset(.mimo); settings.model = "mimo-v2.5-voicedesign"
        XCTAssertThrowsError(try SavedVoice(voiceId: "mimo_default", displayName: "默认", providerHint: "MIMO").applying(to: settings))
    }
    func testBackupAndCorruptionValidation() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = temp.appendingPathComponent("library"); let library = try LibraryStore(root: root)
        _ = try library.importBook(title: "书店", chapters: [.init(id: 0, title: "雨", text: "雨停了。")])
        let voices = VoiceLibrary(root: root); try voices.merge(VoiceLibrary.miniMaxPresets)
        let saved = try voices.voices(), archive = temp.appendingPathComponent("voices.zip")
        _ = try await BackupArchive.create(root: root, output: archive)
        try voices.remove(saved[0].id)
        let prepared = try await BackupArchive.prepare(archive, beside: root)
        try BackupArchive.activate(prepared, replacing: root)
        XCTAssertEqual(try voices.voices(), saved)
        let withoutIDs = try voices.exportJSON()
        try withoutIDs.write(to: root.appendingPathComponent("voice-library.json"))
        XCTAssertThrowsError(try voices.voices())
        try JSONEncoder().encode([saved[0], saved[0]]).write(to: root.appendingPathComponent("voice-library.json"))
        XCTAssertThrowsError(try voices.voices())
        let corrupt = temp.appendingPathComponent("corrupt.zip")
        _ = try await BackupArchive.create(root: root, output: corrupt)
        do { _ = try await BackupArchive.prepare(corrupt, beside: root); XCTFail("Duplicate voice records accepted") } catch { XCTAssertTrue(error.localizedDescription.contains("音色")) }
        XCTAssertEqual(try library.books().count, 1)
    }
}
