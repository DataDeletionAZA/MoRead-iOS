import XCTest
@testable import MoReadCore

final class VoiceDesignAssistantTests: XCTestCase {
    func testToolsAreBoundedAndCannotSaveOrReadPrivateCardFields() throws {
        XCTAssertEqual(Set(try VoiceDesignAssistant.tools().map(\.name)), ["get_voice_design", "find_voice_personas", "read_voice_persona", "set_voice_design", "generate_voice_preview", "fetch_voice_preview"])
        for call in [ChatToolCall(id: "x", name: "save_voice", arguments: "{}"), .init(id: "x", name: "read_voice_persona", arguments: #"{"persona_id":"../other"}"#), .init(id: "x", name: "get_voice_design", arguments: #"{"hidden":"value"}"#), .init(id: "x", name: "set_voice_design", arguments: #"{"name":"A","description":"warm","gender":"other","language":"zh-CN"}"#)] {
            XCTAssertThrowsError(try VoiceDesignAssistant.action(call))
        }
        var card = CharacterCard(name: "Narrator", description: "Warm voice")
        card.personality = "Patient"; card.exampleDialogue = "Hello"; card.systemPrompt = "private-system"; card.scenario = "private-scenario"; card.greeting = "private-greeting"; card.worldBook = [.init(content: "private-lore")]
        let detail = try VoiceDesignPersona(card).detail()
        XCTAssertTrue(detail.contains("Patient")); XCTAssertTrue(detail.contains("Hello")); XCTAssertFalse(detail.contains("private"))
        let update = try VoiceDesignAssistant.action(.init(id: "x", name: "set_voice_design", arguments: #"{"name":" A ","description":" warm ","gender":"neutral","language":"en-US"}"#))
        XCTAssertEqual(update, .update(.init(name: "A", description: "warm", gender: "neutral", language: "en-US")))
    }
    func testLoopLimitsGenerationAndPassesToolFailuresBackWithoutExecutingUnknownActions() async throws {
        let fixture = AssistantFixture()
        try await VoiceDesignAssistant.run(history: [.init(role: "system", content: "private-old-system"), .init(role: "user", content: "Make a warm voice")], snapshot: "{}", stream: { messages, tools, exchanges, onText in
            XCTAssertFalse(messages.contains { $0.content.contains("private-old-system") })
            XCTAssertEqual(tools.count, 6)
            if exchanges.isEmpty {
                return .init(text: "", calls: [.init(id: "one", name: "generate_voice_preview", arguments: "{}"), .init(id: "two", name: "generate_voice_preview", arguments: "{}"), .init(id: "save", name: "save_voice", arguments: "{}"), .init(id: "fetch", name: "fetch_voice_preview", arguments: "{}")], replay: Data("[]".utf8))
            }
            XCTAssertEqual(exchanges[0].results.map(\.failed), [false, true, true, false])
            await onText("Ready"); return .init(text: "Ready", calls: [], replay: Data("[]".utf8))
        }, execute: { try await fixture.execute($0) }, onText: { await fixture.text($0) }, onActivity: { _ in })
        let actions = await fixture.actions, output = await fixture.output
        XCTAssertEqual(actions, [.generate, .fetchPreview]); XCTAssertEqual(output, "Ready")
    }
    func testFailedGenerationStillConsumesRoundAllowanceAndNextUserTurnMayRetry() async throws {
        let fixture = AssistantFixture()
        for _ in 0..<2 {
            try await VoiceDesignAssistant.run(history: [.init(role: "user", content: "Try")], snapshot: "{}", stream: { _, _, exchanges, _ in
                if exchanges.isEmpty { return .init(text: "", calls: [.init(id: "first", name: "generate_voice_preview", arguments: "{}"), .init(id: "retry", name: "generate_voice_preview", arguments: "{}")], replay: Data("[]".utf8)) }
                XCTAssertEqual(exchanges[0].results.map(\.failed), [true, true])
                return .init(text: "Please try again", calls: [], replay: Data("[]".utf8))
            }, execute: { action in _ = try await fixture.execute(action); throw MoReadError.invalid("Unavailable") }, onText: { _ in }, onActivity: { _ in })
        }
        let actions = await fixture.actions; XCTAssertEqual(actions, [.generate, .generate])
    }
    func testLoopBudgetTimeoutAndCancellation() async throws {
        let fixture = AssistantFixture()
        do {
            try await VoiceDesignAssistant.run(history: [], snapshot: "{}", stream: { _, _, exchanges, _ in
                await fixture.round(); return .init(text: "", calls: [.init(id: "call\(exchanges.count)", name: "get_voice_design", arguments: "{}")], replay: Data("[]".utf8))
            }, execute: { try await fixture.execute($0) }, onText: { _ in }, onActivity: { _ in })
            XCTFail("Unbounded loop accepted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("次数上限")) }
        let rounds = await fixture.rounds; XCTAssertEqual(rounds, 6)
        do {
            try await VoiceDesignAssistant.run(history: [], snapshot: "{}", stream: { _, _, _, _ in
                try await Task.sleep(for: .seconds(30)); return .init(text: "Late", calls: [], replay: Data())
            }, execute: { try await fixture.execute($0) }, onText: { _ in }, onActivity: { _ in }, timeout: .milliseconds(20))
            XCTFail("Timeout ignored")
        } catch { XCTAssertTrue(error.localizedDescription.contains("超时")) }
        let task = Task { try await VoiceDesignAssistant.run(history: [], snapshot: "{}", stream: { _, _, _, _ in
            try await Task.sleep(for: .seconds(30)); return .init(text: "Late", calls: [], replay: Data())
        }, execute: { try await fixture.execute($0) }, onText: { _ in }, onActivity: { _ in }) }
        task.cancel()
        do { try await task.value; XCTFail("Cancellation ignored") } catch is CancellationError {} catch { XCTFail("Unexpected error") }
    }
}
private actor AssistantFixture {
    var actions: [VoiceDesignAction] = []
    var output = ""
    var rounds = 0
    func execute(_ action: VoiceDesignAction) throws -> String { actions.append(action); return "{}" }
    func text(_ value: String) { output += value }
    func round() { rounds += 1 }
}
