import XCTest
@testable import MoReadCore

final class GlobalPromptTests: XCTestCase {
    func testFourPositionsKeepOriginalHistoryIdentityAndRequestOrder() throws {
        let presets = GlobalPromptPosition.allCases.enumerated().map { GlobalPromptPreset(name: "位置\($0.offset)", prompt: "marker-\($0.offset)", position: $0.element) }
        var user = ChatMessage(role: "user", content: "这句话😀不要改")
        user.identity = ChatIdentity(name: "读者", mask: UserMask(name: "林遥")); user.focusedBookIDs = [UUID()]
        let original: [ChatMessage] = [.init(role: "system", content: "范围规则"), .init(role: "system", content: "另一条系统规则"), .init(role: "user", content: "上一句"), .init(role: "assistant", content: "上一条回答"), user, .init(role: "assistant", content: "已有回复")]
        let injected = try GlobalPromptInjector.inject(original, presets: presets)
        XCTAssertEqual(injected[0].content, "【全局预设·位置0】\nmarker-0\n\n范围规则\n\n【全局预设·位置1】\nmarker-1")
        XCTAssertEqual(injected[4].content, "【全局预设·位置2】\nmarker-2\n\n这句话😀不要改\n\n【全局预设·位置3】\nmarker-3")
        XCTAssertEqual(injected[4].id, user.id); XCTAssertEqual(injected[4].identity, user.identity); XCTAssertEqual(injected[4].focusedBookIDs, user.focusedBookIDs)
        for index in [1, 2, 3, 5] { XCTAssertEqual(injected[index], original[index]) }
        XCTAssertEqual(original[4], user)
        XCTAssertEqual(try GlobalPromptInjector.inject(original, presets: GlobalPromptPreset.defaults), original)
        XCTAssertEqual(try GlobalPromptInjector.inject(original, presets: []), original)
        XCTAssertEqual(try GlobalPromptInjector.inject(original, presets: presets), injected)
        let labeled = try GlobalPromptInjector.inject([user.withIdentityLabel], presets: presets)
        XCTAssertTrue(labeled[1].content.contains("扮演：林遥")); XCTAssertEqual(labeled[1].identity, user.identity)
        XCTAssertEqual(try GlobalPromptInjector.inject([], presets: presets).map(\.role), ["system"])
        XCTAssertTrue(try GlobalPromptInjector.inject([], presets: [presets[2]]).isEmpty)
        var second = presets[0]; second.id = UUID().uuidString; second.name = "第二条"; second.prompt = "marker-second"
        XCTAssertTrue(try GlobalPromptInjector.inject(original, presets: [presets[0], second])[0].content.hasPrefix("【全局预设·位置0】\nmarker-0\n【全局预设·第二条】\nmarker-second"))

        let call = ChatToolCall(id: "toc", name: "list_chapters", arguments: "{}")
        let tools = try ReaderTools.specs(currentBook: UUID(), memory: false, enabled: [call.name])
        for dialect in AIProtocol.allCases {
            var provider = AIProvider(); provider.dialect = dialect; provider.model = "test-model"; provider.baseURL = "https://example.invalid"
            let replay: Any
            switch dialect {
            case .openAI: replay = ["role": "assistant", "tool_calls": [["id": call.id, "type": "function", "function": ["name": call.name, "arguments": call.arguments]]]]
            case .responses: replay = [["type": "function_call", "call_id": call.id, "name": call.name, "arguments": call.arguments]]
            case .claude: replay = [["type": "tool_use", "id": call.id, "name": call.name, "input": [:]]]
            case .gemini: replay = [["functionCall": ["name": call.name, "args": [:]]]]
            }
            let round = ChatToolRound(text: "", calls: [call], replay: try JSONSerialization.data(withJSONObject: replay))
            let exchange = ChatToolExchange(round: round, results: [.init(call: call, content: "第一章")])
            for exchanges in [[], [exchange]] {
                let data = try XCTUnwrap(ChatRequest.make(provider: provider, key: "fixture", messages: injected, tools: tools, exchanges: exchanges).httpBody)
                let text = String(decoding: data, as: UTF8.self)
                for marker in presets.map(\.prompt) { XCTAssertEqual(text.components(separatedBy: marker).count - 1, 1, dialect.rawValue) }
            }
        }
    }

    func testDefaultsValidationAndAtomicSettingsSave() throws {
        let old = try JSONDecoder().decode(CompanionSettings.self, from: Data(#"{"providers":[],"userName":"读者"}"#.utf8))
        XCTAssertNil(old.globalPrompts); XCTAssertEqual(old.resolvedGlobalPrompts, GlobalPromptPreset.defaults)
        XCTAssertTrue(old.resolvedGlobalPrompts.allSatisfy { !$0.enabled })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CompanionStore(root: root)
        var settings = old; settings.globalPrompts = [GlobalPromptPreset(name: "我的预设", prompt: "说话风格")]
        try store.save(settings)
        XCTAssertEqual(try store.settings().globalPrompts, settings.globalPrompts)
        var invalid = settings; invalid.globalPrompts! += invalid.globalPrompts!
        XCTAssertThrowsError(try store.save(invalid))
        XCTAssertEqual(try store.settings().globalPrompts, settings.globalPrompts)
        for entry in [GlobalPromptPreset(name: " ", prompt: "内容"), .init(name: "名字", prompt: "\n"), .init(name: String(repeating: "名", count: 81), prompt: "内容"), .init(name: "名字", prompt: String(repeating: "😀", count: 6001))] {
            XCTAssertThrowsError(try GlobalPromptPreset.validate([entry]))
        }
        let large = (0..<11).map { GlobalPromptPreset(name: String($0), prompt: String(repeating: "字", count: 12_000)) }
        XCTAssertNoThrow(try GlobalPromptPreset.validate(Array(large.prefix(10))))
        XCTAssertThrowsError(try GlobalPromptPreset.validate(large))
        XCTAssertThrowsError(try GlobalPromptPreset.validate((0..<101).map { .init(name: String($0), prompt: "字") }))
        settings.globalPrompts = []; try store.save(settings)
        XCTAssertEqual(try CompanionStore(root: root).settings().resolvedGlobalPrompts, [])
    }

    func testBackupRestoresPresetsAndRejectsInvalidPresetData() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), root = directory.appendingPathComponent("library")
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try LibraryStore(root: root)
        let store = try CompanionStore(root: root)
        var settings = CompanionSettings(); settings.globalPrompts = GlobalPromptPreset.defaults
        settings.globalPrompts![1].enabled = true
        settings.globalPrompts!.append(.init(name: "结尾", prompt: "问一个问题", position: .afterUser))
        try store.save(settings)
        var chat = Conversation(title: "保留原文", bookID: nil, characterID: UUID()); chat.messages = [.init(role: "user", content: "原来的话")]
        try store.save(chat)
        let archive = directory.appendingPathComponent("backup.zip")
        _ = try await BackupArchive.create(root: root, output: archive)
        let prepared = try await BackupArchive.prepare(archive, beside: root)
        XCTAssertEqual(try CompanionStore(root: prepared.directory).settings().globalPrompts, settings.globalPrompts)
        XCTAssertEqual(try CompanionStore(root: prepared.directory).conversations(), [chat])
        try BackupArchive.activate(prepared, replacing: root)
        XCTAssertEqual(try store.settings().globalPrompts, settings.globalPrompts)
        var invalid = settings; invalid.globalPrompts![0].prompt = ""
        try JSONEncoder().encode(invalid).write(to: root.appendingPathComponent("companion/settings.json"))
        XCTAssertThrowsError(try store.settings())
        let corrupt = directory.appendingPathComponent("invalid.zip")
        _ = try await BackupArchive.create(root: root, output: corrupt)
        do { _ = try await BackupArchive.prepare(corrupt, beside: root); XCTFail("Invalid prompts accepted") } catch {}
        XCTAssertEqual(try store.conversations(), [chat])
    }
}
