import XCTest
@testable import MoReadCore

final class ChatTests: XCTestCase {
    func testRequestsUseCorrectProtocolsAndNeverPutKeyInURL() throws {
        for dialect in AIProtocol.allCases {
            var provider = AIProvider(); provider.dialect = dialect; provider.baseURL = "https://example.invalid"; provider.model = "model"
            let request = try ChatRequest.make(provider: provider, key: "test-only", messages: [.init(role: "system", content: "规则"), .init(role: "user", content: "你好")])
            XCTAssertFalse(request.url!.absoluteString.contains("test-only"))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            switch dialect {
            case .openAI: XCTAssertEqual(request.url?.path, "/v1/chat/completions"); XCTAssertNotNil(body["messages"])
            case .responses: XCTAssertEqual(body["store"] as? Bool, false); XCTAssertEqual(body["instructions"] as? String, "规则")
            case .claude: XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-only"); XCTAssertNotNil(body["max_tokens"])
            case .gemini: XCTAssertEqual(request.url?.query, "alt=sse"); XCTAssertNotNil(body["systemInstruction"])
            }
        }
        var bad = AIProvider(); bad.model = "model"; bad.baseURL = "http://example.invalid"
        XCTAssertThrowsError(try ChatRequest.make(provider: bad, key: "test", messages: []))
        bad.baseURL = "https://user:password@example.invalid"
        XCTAssertThrowsError(try ChatRequest.make(provider: bad, key: "test", messages: []))
    }
    func testStreamDialectsRejectIncompleteAndSeparateReasoning() throws {
        var openAI = ChatStreamDecoder(dialect: .openAI)
        XCTAssertEqual(try openAI.consume(#"{"choices":[{"delta":{"content":"你好","reasoning_content":"思考"}}]}"#), "你好")
        XCTAssertFalse(openAI.finished)
        XCTAssertThrowsError(try openAI.consume(#"{"choices":[{"finish_reason":"length"}]}"#))
        var responses = ChatStreamDecoder(dialect: .responses)
        XCTAssertEqual(try responses.consume(#"{"type":"response.output_text.delta","delta":"你好"}"#), "你好")
        _ = try responses.consume(#"{"type":"response.completed"}"#); XCTAssertTrue(responses.finished)
        var claude = ChatStreamDecoder(dialect: .claude)
        XCTAssertEqual(try claude.consume(#"{"type":"content_block_delta","delta":{"type":"text_delta","text":"你好"}}"#), "你好")
        _ = try claude.consume(#"{"type":"message_stop"}"#); XCTAssertTrue(claude.finished)
        var gemini = ChatStreamDecoder(dialect: .gemini)
        XCTAssertEqual(try gemini.consume(#"{"candidates":[{"content":{"parts":[{"thought":true,"text":"思考"},{"text":"你好"}]},"finishReason":"STOP"}]}"#), "你好")
        XCTAssertTrue(gemini.finished)
    }
}
