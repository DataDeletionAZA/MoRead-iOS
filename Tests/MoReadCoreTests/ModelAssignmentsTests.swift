import XCTest
@testable import MoReadCore

final class ModelAssignmentsTests: XCTestCase {
    func testDefaultRoutesExplicitOverridesAndUnavailableAssignments() throws {
        var settings = try JSONDecoder().decode(CompanionSettings.self, from: Data(#"{"providers":[],"userName":"读者"}"#.utf8))
        XCTAssertNil(settings.batchProvider); XCTAssertNil(settings.coverQueryProvider)
        var chat = AIProvider(); chat.model = "chat"
        var batch = AIProvider(); batch.model = "batch"
        var custom = AIProvider(); custom.model = "custom"
        settings.providers = [chat, batch, custom]; settings.selectedProvider = chat.id
        for task in [ModelTask.chat, .knowledge, .annotation, .coverQuery] { XCTAssertEqual(settings.resolvedProvider(for: task), chat) }
        for task in [ModelTask.batch, .summary, .memory] { XCTAssertNil(settings.resolvedProvider(for: task)) }
        try settings.assignProvider(batch.id, to: .batch)
        XCTAssertEqual(settings.resolvedProvider(for: .chat), chat)
        for task in ModelTask.allCases where task != .chat { XCTAssertEqual(settings.resolvedProvider(for: task), batch) }
        let tasks: [ModelTask] = [.knowledge, .summary, .memory, .annotation, .coverQuery]
        for task in tasks { try settings.assignProvider(custom.id, to: task) }
        try settings.assignProvider(chat.id, to: .batch)
        for task in tasks { XCTAssertEqual(settings.resolvedProvider(for: task), custom) }
        try settings.assignProvider(batch.id, to: .chat)
        for task in tasks { XCTAssertEqual(settings.resolvedProvider(for: task), custom) }
        for task in tasks { try settings.assignProvider(nil, to: task); XCTAssertEqual(settings.resolvedProvider(for: task), chat) }
        settings.knowledgeProvider = custom.id; settings.providers.removeAll { $0.id == custom.id }
        XCTAssertNil(settings.resolvedProvider(for: .knowledge))
        XCTAssertThrowsError(try settings.assignProvider(custom.id, to: .knowledge))
        XCTAssertEqual(settings.knowledgeProvider, custom.id)
        try settings.assignProvider(nil, to: .knowledge); XCTAssertEqual(settings.resolvedProvider(for: .knowledge), chat)
        settings.batchProvider = custom.id
        for task in ModelTask.allCases where task != .chat { XCTAssertNil(settings.resolvedProvider(for: task)) }
        try settings.assignProvider(nil, to: .batch)
        for task in [ModelTask.knowledge, .annotation, .coverQuery] { XCTAssertEqual(settings.resolvedProvider(for: task), batch) }
        for task in [ModelTask.summary, .memory] { XCTAssertNil(settings.resolvedProvider(for: task)) }
    }

    func testAssignmentPreservesFeaturePoliciesAndSurvivesBackup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), root = directory.appendingPathComponent("library")
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try LibraryStore(root: root)
        var settings = CompanionSettings()
        var provider = AIProvider(); provider.model = "assigned-model"; settings.providers = [provider]
        var summary = SummarySettings(); summary.enabled = false; settings.summarySettings = summary
        var memory = PersonaMemorySettings(); memory.crossBook = true; memory.disabledCharacters = [UUID()]; settings.personaMemory = memory
        var annotation = ProactiveSettings(); annotation.enabled = false; annotation.maximumPerChapter = 4; annotation.dailyMaximum = 15; settings.proactive = annotation
        settings.embeddingModel = "separate-vector-model"
        for task in ModelTask.allCases { try settings.assignProvider(provider.id, to: task) }
        XCTAssertFalse(settings.summarySettings!.enabled); XCTAssertFalse(settings.personaMemory!.enabled); XCTAssertFalse(settings.proactive!.enabled)
        XCTAssertEqual(settings.personaMemory!.disabledCharacters, memory.disabledCharacters)
        XCTAssertTrue(settings.personaMemory!.crossBook); XCTAssertEqual(settings.proactive!.maximumPerChapter, 4); XCTAssertEqual(settings.proactive!.dailyMaximum, 15)
        XCTAssertEqual(settings.embeddingModel, "separate-vector-model")
        let store = try CompanionStore(root: root); try store.save(settings)
        let archive = directory.appendingPathComponent("models.zip")
        _ = try await BackupArchive.create(root: root, output: archive)
        let prepared = try await BackupArchive.prepare(archive, beside: root)
        try BackupArchive.activate(prepared, replacing: root)
        let restored = try CompanionStore(root: root).settings()
        XCTAssertEqual(restored.summarySettings, settings.summarySettings); XCTAssertEqual(restored.personaMemory, settings.personaMemory); XCTAssertEqual(restored.proactive, settings.proactive)
        for task in ModelTask.allCases {
            XCTAssertEqual(restored.assignedProvider(for: task), provider.id); XCTAssertEqual(restored.resolvedProvider(for: task), provider)
            let request = try ChatRequest.make(provider: XCTUnwrap(restored.resolvedProvider(for: task)), key: "fixture", messages: [.init(role: "user", content: "check")])
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(body["model"] as? String, "assigned-model")
        }
    }
}
