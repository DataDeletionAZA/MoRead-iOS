import XCTest
@testable import MoReadCore

final class KnowledgeResponseTests: XCTestCase {
    private let part = KnowledgePart(start: 30, text: "林舟在灯塔等候。小满带来一封信。")
    private let valid = #"{"characters":[{"name":"林舟","facts":[{"text":"在灯塔等候","quote":"林舟在灯塔等候。"}]}]}"#
    private let toolName = "save_book_characters"

    func testCompleteWrappedObjectsAndArraysKeepEvidenceValidation() throws {
        let array = String(valid.dropFirst(14).dropLast())
        for raw in [valid, "\u{FEFF}整理如下：\n```JSON\n" + valid + "\n```", array, "结果：\n```json\n" + array + "\n```"] {
            let result = try ChapterKnowledge.parseCharacters(raw, part: part)
            XCTAssertEqual(result.first?.name, "林舟"); XCTAssertEqual(result.first?.facts.first?.start, 30)
        }
        XCTAssertEqual(try ChapterKnowledge.parseCharacters("人物列表：[]", part: part), [])
        for raw in ["", "人物包括林舟。", String(valid.dropLast()), valid + valid, "[", "null", valid.replacingOccurrences(of: "林舟在灯塔等候。", with: "原文没有这句话。"), String(repeating: " ", count: 64_001) + valid] {
            XCTAssertThrowsError(try ChapterKnowledge.parseCharacters(raw, part: part))
        }
        let outline = #"{"outline":"林舟在灯塔等候，小满带来一封信。","summary":[{"text":"等候","quote":"林舟在灯塔等候。"}]}"#
        XCTAssertEqual(try ChapterKnowledge.parse("结果：```JSON\n" + outline + "\n```", part: part).summary.first?.start, 30)
    }

    private actor Replies {
        var remaining: [ChatToolRound]
        var histories: [[ChatMessage]] = []
        var exchanges: [[ChatToolExchange]] = []
        init(_ rounds: [ChatToolRound]) { remaining = rounds }
        func next(_ messages: [ChatMessage], _ previous: [ChatToolExchange]) throws -> ChatToolRound {
            histories.append(messages); exchanges.append(previous)
            guard !remaining.isEmpty else { throw CancellationError() }
            return remaining.removeFirst()
        }
    }
    func testTextCorrectionIsBoundedKeepsRoundsSeparateAndPropagatesCancellation() async throws {
        let first = ChatToolRound(text: "人物包括林舟。", calls: [], replay: Data("[]".utf8))
        let last = ChatToolRound(text: "整理如下：" + valid, calls: [], replay: Data("[]".utf8))
        let replies = Replies([first, last])
        let result = try await ChapterKnowledgeAgent.characters(bookTitle: "灯塔", chapterTitle: "一", part: part, stream: { messages, _, exchanges in try await replies.next(messages, exchanges) }, validate: {})
        XCTAssertEqual(result.first?.name, "林舟")
        let histories = await replies.histories, exchanges = await replies.exchanges
        XCTAssertEqual(histories.count, 2); XCTAssertTrue(exchanges.allSatisfy(\.isEmpty))
        XCTAssertEqual(histories.last?.suffix(2).map(\.role), ["assistant", "user"])
        XCTAssertEqual(histories.last?.dropLast().last?.content, first.text)
        XCTAssertTrue(histories.last?.last?.content.contains("完整 JSON") == true)
        let empty = Replies([.init(text: "", calls: [], replay: Data("[]".utf8)), last])
        _ = try await ChapterKnowledgeAgent.characters(bookTitle: "灯塔", chapterTitle: "一", part: part, stream: { messages, _, exchanges in try await empty.next(messages, exchanges) }, validate: {})
        let emptyHistory = await empty.histories.last
        XCTAssertFalse(emptyHistory?.contains { $0.role == "assistant" && $0.content.isEmpty } ?? true)
        let invalid = Replies([first, .init(text: String(valid.dropLast()), calls: [], replay: Data("[]".utf8)), last])
        do {
            _ = try await ChapterKnowledgeAgent.characters(bookTitle: "灯塔", chapterTitle: "一", part: part, stream: { messages, _, exchanges in try await invalid.next(messages, exchanges) }, validate: {})
            XCTFail("Truncated output accepted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("人物资料格式不完整")) }
        let count = await invalid.histories.count; XCTAssertEqual(count, 2)
        let cancelled = Replies([last, last])
        do {
            let _: String = try await ChapterKnowledgeAgent.submit(messages: [], tool: .init(name: toolName, description: "", parameters: Data("{}".utf8)), stream: { messages, _, exchanges in try await cancelled.next(messages, exchanges) }, validate: {}, parse: { _ in throw CancellationError() })
            XCTFail("Cancellation retried")
        } catch { XCTAssertTrue(error is CancellationError) }
        let cancellationCount = await cancelled.histories.count; XCTAssertEqual(cancellationCount, 1)
    }

    private func payload(_ object: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) }
    func testMalformedProviderCallsBecomeTextCorrectionWithoutFabricatedNativeHistory() throws {
        let raw = String(valid.dropLast(8))
        let streams: [(AIProtocol, [[String: Any]])] = [
            (.openAI, [["choices": [["delta": ["tool_calls": [["index": 0, "id": "call", "function": ["name": toolName, "arguments": raw]]]], "finish_reason": "length"]]]]),
            (.responses, [["type": "response.incomplete", "response": ["incomplete_details": ["reason": "max_output_tokens"], "output": [["type": "function_call", "call_id": "call", "name": toolName, "arguments": raw]]]]]),
            (.claude, [["type": "content_block_start", "index": 0, "content_block": ["type": "tool_use", "id": "call", "name": toolName, "input": [:]]], ["type": "content_block_delta", "index": 0, "delta": ["type": "input_json_delta", "partial_json": raw]], ["type": "message_delta", "delta": ["stop_reason": "max_tokens"]], ["type": "message_stop"]])
        ]
        for (dialect, events) in streams {
            var decoder = ChatStreamDecoder(dialect: dialect, allowsTools: true, correctionTool: toolName)
            for event in events { _ = try decoder.consume(payload(event)) }
            XCTAssertTrue(decoder.finished)
            let round = try decoder.toolRound()
            XCTAssertEqual(round.text, raw); XCTAssertTrue(round.calls.isEmpty); XCTAssertEqual(round.replay, Data("[]".utf8))
            var strict = ChatStreamDecoder(dialect: dialect, allowsTools: true)
            XCTAssertThrowsError(try events.forEach { _ = try strict.consume(payload($0)) })
        }
        var wrapped = ChatStreamDecoder(dialect: .openAI, allowsTools: true, correctionTool: toolName)
        _ = try wrapped.consume(payload(["choices": [["delta": ["tool_calls": [["index": 0, "id": "call", "function": ["name": toolName, "arguments": "```JSON\n" + valid + "\n```"]]]], "finish_reason": "tool_calls"]]]))
        XCTAssertEqual(try ChapterKnowledge.parseCharacters(wrapped.toolRound().text, part: part).count, 1)
        var unknown = ChatStreamDecoder(dialect: .openAI, allowsTools: true, correctionTool: toolName)
        _ = try unknown.consume(payload(["choices": [["delta": ["tool_calls": [["index": 0, "id": "call", "function": ["name": "other", "arguments": raw]]]], "finish_reason": "tool_calls"]]]))
        XCTAssertThrowsError(try unknown.toolRound())
    }

    func testOnlyOutputLimitAllowsCorrectionAndValidNativeCallsRemainIntact() throws {
        let limits: [(AIProtocol, [String: Any])] = [
            (.openAI, ["choices": [["delta": ["content": "{"], "finish_reason": "length"]]]),
            (.gemini, ["candidates": [["content": ["parts": [["text": "{"]]], "finishReason": "MAX_TOKENS"]]])
        ]
        for (dialect, event) in limits {
            var decoder = ChatStreamDecoder(dialect: dialect, allowsTools: true, correctionTool: toolName)
            _ = try decoder.consume(payload(event)); XCTAssertEqual(try decoder.toolRound().text, "{")
        }
        for (dialect, event) in [(AIProtocol.openAI, ["choices": [["finish_reason": "content_filter"]]] as [String: Any]), (.gemini, ["candidates": [["finishReason": "SAFETY"]]]), (.responses, ["type": "response.incomplete", "response": ["incomplete_details": ["reason": "content_filter"]]])] {
            var decoder = ChatStreamDecoder(dialect: dialect, allowsTools: true, correctionTool: toolName)
            XCTAssertThrowsError(try decoder.consume(payload(event)))
        }
        var native = ChatStreamDecoder(dialect: .claude, allowsTools: true, correctionTool: toolName)
        _ = try native.consume(payload(["type": "content_block_start", "index": 0, "content_block": ["type": "tool_use", "id": "call", "name": toolName, "input": ["characters": []]]]))
        _ = try native.consume(payload(["type": "message_stop"]))
        let round = try native.toolRound(); XCTAssertEqual(round.calls.first?.name, toolName)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: round.replay) as? [[String: Any]])?.first?["id"] as? String, "call")
    }
}
