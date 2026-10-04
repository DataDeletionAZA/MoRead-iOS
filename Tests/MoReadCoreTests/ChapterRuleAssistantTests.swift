import XCTest
@testable import MoReadCore

final class ChapterRuleAssistantTests: XCTestCase {
    private static let text = "资料说明\n第一章 林遥的秘密\n" + String(repeating: "林遥藏起了那封信，安静地离开旧书店。", count: 5) + "\n第二章 谜底\n" + String(repeating: "她在灯塔前终于打开了那封来自远方的信。", count: 5)
    private static let valid = #"{"name":"中文章节","regex":"^第[一二三四五六七八九十0-9]+章.*$","reason":"使用章节序号识别标题"}"#
    func testSamplesMaskContentAcrossBookAndRemainBounded() throws {
        let text = "Chapter 42 Hermione\n第一章 林遥的秘密\n名字里有稀有汉字𠮷和é\n" + String(repeating: "PrivateBodyContent\n", count: 2000) + "\nEpilogue SecretEnding\n尾声 123456789\n"
        let sample = try ChapterRuleAssistant.structuralSample(text)
        for secret in ["Hermione", "林遥", "秘密", "PrivateBodyContent", "SecretEnding", "42", "123456789", "é", "𠮷"] { XCTAssertFalse(sample.contains(secret), secret) }
        XCTAssertTrue(sample.contains("Chapter 00 A")); XCTAssertTrue(sample.contains("第一章 汉汉汉汉汉")); XCTAssertTrue(sample.contains("Epilogue A"))
        XCTAssertTrue(sample.contains("位置 100%")); XCTAssertLessThan(sample.utf16.count, 8000)
        XCTAssertThrowsError(try ChapterRuleAssistant.structuralSample(""))
    }
    func testValidationMatchesWholeHeadingsAndRejectsWeakOrExpensiveRules() throws {
        let proposal = try ChapterRuleAssistant.validate(response: "```json\n" + Self.valid + "\n```", text: Self.text)
        XCTAssertEqual(proposal.chapterCount, 3); XCTAssertEqual(proposal.sampleTitles, ["第一章 林遥的秘密", "第二章 谜底"])
        for pattern in ["第.*章", "^(a+)+$", "^[a-$", "^.*$", "^第一章|第二章.*$", "^不存在$", "^" + String(repeating: "a", count: 401) + "$"] {
            let data = try JSONSerialization.data(withJSONObject: ["name": "规则", "regex": pattern, "reason": "检查"])
            XCTAssertThrowsError(try ChapterRuleAssistant.validate(response: String(decoding: data, as: UTF8.self), text: Self.text), pattern)
        }
        let repetitive = String(repeating: "第一章 相同\n" + String(repeating: "正文", count: 20) + "\n", count: 5)
        XCTAssertThrowsError(try ChapterRuleAssistant.validate(response: Self.valid, text: repetitive))
        let tiny = (1...10).map { "第\($0)章 标题\n短\n" }.joined()
        XCTAssertThrowsError(try ChapterRuleAssistant.validate(response: Self.valid, text: tiny))
        let indented = "  第一章 开始\n正文\n  第二章 后续\n正文\n"
        let whitespaceRule = #"{"name":"缩进","regex":"^  第.*章.*$","reason":"缩进标题"}"#
        XCTAssertEqual(try ChapterRuleAssistant.validate(response: whitespaceRule, text: indented).chapterCount, 2)
    }
    func testCorrectsInvalidProposalWithoutSendingOriginalText() async throws {
        let attempts = Attempts()
        let proposal = try await ChapterRuleAssistant.propose(text: Self.text, reply: { messages in
            for message in messages { XCTAssertFalse(message.content.contains("林遥")); XCTAssertFalse(message.content.contains("灯塔")); XCTAssertFalse(message.content.contains("谜底")) }
            await attempts.add()
            if messages.count == 2 { return #"{"name":"错误","regex":"^不存在$","reason":"试验"}"# }
            XCTAssertTrue(messages.last?.content.contains("本地全文检查未通过") == true)
            return Self.valid
        })
        let count = await attempts.count
        XCTAssertEqual(count, 2); XCTAssertEqual(proposal.chapterCount, 3)
    }
    func testAttemptLimitTimeoutAndCancellation() async throws {
        let attempts = Attempts()
        do {
            _ = try await ChapterRuleAssistant.propose(text: Self.text, reply: { _ in await attempts.add(); return "invalid" })
            XCTFail("Invalid proposals must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("3 次")) }
        let count = await attempts.count; XCTAssertEqual(count, 3)
        do {
            _ = try await ChapterRuleAssistant.propose(text: Self.text, reply: { _ in try await Task.sleep(for: .seconds(60)); return Self.valid }, timeout: .milliseconds(20))
            XCTFail("Request must time out")
        } catch { XCTAssertTrue(error.localizedDescription.contains("超时")) }
        let task = Task { try await ChapterRuleAssistant.propose(text: Self.text, reply: { _ in try await Task.sleep(for: .seconds(60)); return Self.valid }) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled task must not propose") } catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
    }
}

private actor Attempts {
    var count = 0
    func add() { count += 1 }
}
