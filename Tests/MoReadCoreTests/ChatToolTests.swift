import XCTest
@testable import MoReadCore

final class ChatToolTests: XCTestCase {
    private func json(_ value: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self) }
    private func body(_ dialect: AIProtocol, round: ChatToolRound) throws -> [String: Any] {
        var provider = AIProvider(); provider.dialect = dialect; provider.model = "fixture"; provider.baseURL = "https://example.invalid"
        let specs = try ReaderTools.specs(currentBook: UUID(), memory: false)
        let results = round.calls.map { ChatToolResult(call: $0, content: "查到已读资料") }
        let request = try ChatRequest.make(provider: provider, key: "test-only", messages: [.init(role: "user", content: "查看目录")], tools: specs, exchanges: [.init(round: round, results: results)])
        return try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }
    func testOpenAIToolFragmentsAndOpaqueMetadataReplay() throws {
        var decoder = ChatStreamDecoder(dialect: .openAI, allowsTools: true)
        _ = try decoder.consume(json(["choices": [["delta": ["tool_calls": [["index": 0, "id": "call-one", "function": ["name": "read_book_section", "arguments": "{\"from_"], "extra_content": ["google": ["thought_signature": "opaque"]]]]]]]]))
        _ = try decoder.consume(json(["choices": [["delta": ["tool_calls": [["index": 0, "function": ["arguments": "chapter\":1}"], "extra_content": ["google": ["other": 1]]], ["index": 1, "id": "call-two", "function": ["name": "list_chapters", "arguments": "{}"]]]]]]]))
        _ = try decoder.consume(json(["choices": [["delta": [:], "finish_reason": "tool_calls"]]]))
        XCTAssertTrue(decoder.finished)
        let round = try decoder.toolRound(); XCTAssertEqual(round.calls.map(\.name), ["read_book_section", "list_chapters"])
        XCTAssertEqual(try round.calls[0].object()["from_chapter"] as? Int, 1)
        let messages = try XCTUnwrap(body(.openAI, round: round)["messages"] as? [[String: Any]])
        let native = try XCTUnwrap(messages[1]["tool_calls"] as? [[String: Any]])
        let google = (native[0]["extra_content"] as? [String: Any])?["google"] as? [String: Any]
        XCTAssertEqual(google?["thought_signature"] as? String, "opaque"); XCTAssertEqual(google?["other"] as? Int, 1)
        XCTAssertEqual(messages[2]["tool_call_id"] as? String, "call-one"); XCTAssertEqual(messages[3]["tool_call_id"] as? String, "call-two")
        var plain = ChatStreamDecoder(dialect: .openAI)
        XCTAssertThrowsError(try plain.consume(json(["choices": [["finish_reason": "tool_calls"]]])))
    }
    func testResponsesCallsAndEncryptedReasoningReplay() throws {
        var decoder = ChatStreamDecoder(dialect: .responses, allowsTools: true)
        let output: [[String: Any]] = [["type": "reasoning", "id": "rs1", "summary": [], "encrypted_content": "opaque"], ["type": "function_call", "id": "fc1", "call_id": "call-one", "name": "list_chapters", "arguments": "{}"]]
        _ = try decoder.consume(json(["type": "response.completed", "response": ["output": output]]))
        let round = try decoder.toolRound(); XCTAssertEqual(round.calls.count, 1)
        let payload = try body(.responses, round: round), input = try XCTUnwrap(payload["input"] as? [[String: Any]])
        XCTAssertEqual(payload["include"] as? [String], ["reasoning.encrypted_content"])
        XCTAssertEqual(input[1]["encrypted_content"] as? String, "opaque")
        XCTAssertEqual(input[2]["call_id"] as? String, "call-one"); XCTAssertEqual(input[3]["type"] as? String, "function_call_output")
        XCTAssertEqual(input[3]["call_id"] as? String, "call-one")
    }
    func testClaudeSignedBlocksAndToolResultsReplay() throws {
        var decoder = ChatStreamDecoder(dialect: .claude, allowsTools: true)
        for event: [String: Any] in [
            ["type": "content_block_start", "index": 0, "content_block": ["type": "thinking", "thinking": "", "signature": ""]],
            ["type": "content_block_delta", "index": 0, "delta": ["type": "thinking_delta", "thinking": "opaque thought"]],
            ["type": "content_block_delta", "index": 0, "delta": ["type": "signature_delta", "signature": "signed"]],
            ["type": "content_block_start", "index": 1, "content_block": ["type": "tool_use", "id": "tool-one", "name": "read_book_section", "input": [:]]],
            ["type": "content_block_delta", "index": 1, "delta": ["type": "input_json_delta", "partial_json": "{\"from_chapter\":1}"]],
            ["type": "message_delta", "delta": ["stop_reason": "tool_use"]], ["type": "message_stop"]
        ] { XCTAssertEqual(try decoder.consume(json(event)), "") }
        let round = try decoder.toolRound(), messages = try XCTUnwrap(body(.claude, round: round)["messages"] as? [[String: Any]])
        let blocks = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(blocks[0]["signature"] as? String, "signed")
        XCTAssertEqual((blocks[1]["input"] as? [String: Any])?["from_chapter"] as? Int, 1)
        let results = try XCTUnwrap(messages[2]["content"] as? [[String: Any]])
        XCTAssertEqual(results[0]["tool_use_id"] as? String, "tool-one"); XCTAssertEqual(results[0]["is_error"] as? Bool, false)
    }
    func testGeminiParallelCallsPreserveSignaturePartsAndIDs() throws {
        var decoder = ChatStreamDecoder(dialect: .gemini, allowsTools: true)
        let parts: [[String: Any]] = [["text": "", "thoughtSignature": "text-signature"], ["functionCall": ["id": "native-one", "name": "list_chapters", "args": [:]], "thoughtSignature": "tool-signature"], ["functionCall": ["name": "get_reading_progress", "args": [:]]]]
        _ = try decoder.consume(json(["candidates": [["content": ["parts": parts], "finishReason": "STOP"]]]))
        let round = try decoder.toolRound(); XCTAssertEqual(round.calls.count, 2)
        let contents = try XCTUnwrap(body(.gemini, round: round)["contents"] as? [[String: Any]])
        let replay = try XCTUnwrap(contents[1]["parts"] as? [[String: Any]])
        XCTAssertEqual(replay[0]["thoughtSignature"] as? String, "text-signature"); XCTAssertEqual(replay[1]["thoughtSignature"] as? String, "tool-signature")
        let results = try XCTUnwrap(contents[2]["parts"] as? [[String: Any]])
        XCTAssertEqual((results[0]["functionResponse"] as? [String: Any])?["id"] as? String, "native-one")
        XCTAssertNil((results[1]["functionResponse"] as? [String: Any])?["id"])
    }
    func testToolLoopWhitelistErrorsRoundLimitAndCancellation() async throws {
        let specs = try ReaderTools.specs(currentBook: UUID(), memory: false, enabled: ["list_chapters"])
        var rounds = 0, executions = 0, events: [ChatToolEvent] = []
        try await ChatToolLoop.run(tools: specs, stream: { exchanges in
            rounds += 1
            if rounds == 1 { return ChatToolRound(text: "", calls: [.init(id: "bad", name: "delete_book", arguments: "{}"), .init(id: "good", name: "list_chapters", arguments: "{}")], replay: Data("{}".utf8)) }
            XCTAssertTrue(exchanges[0].results[0].failed); XCTAssertFalse(exchanges[0].results[1].failed)
            return ChatToolRound(text: "完成", calls: [], replay: Data("{}".utf8))
        }, execute: { _ in executions += 1; return "第一章" }, validate: {}, report: { events.append($0) })
        XCTAssertEqual(rounds, 2); XCTAssertEqual(executions, 1); XCTAssertEqual(events.count, 4)
        rounds = 0
        do {
            try await ChatToolLoop.run(tools: specs, stream: { _ in rounds += 1; return ChatToolRound(text: "", calls: [.init(id: "repeat", name: "list_chapters", arguments: "{}")], replay: Data("{}".utf8)) }, execute: { _ in "目录" }, validate: {}, report: { _ in })
            XCTFail("Expected round limit")
        } catch { XCTAssertEqual(rounds, 8) }
        var sent = false
        do {
            try await ChatToolLoop.run(tools: specs, stream: { _ in sent = true; return ChatToolRound(text: "", calls: [], replay: Data()) }, execute: { _ in "" }, validate: { throw CancellationError() }, report: { _ in })
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { XCTFail("Unexpected error") }
        XCTAssertFalse(sent)
        XCTAssertThrowsError(try ChatToolCall(id: "x", name: "list_chapters", arguments: "[]").object())
    }
}
