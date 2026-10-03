import XCTest
@testable import MoReadCore

final class AIDictionaryTests: XCTestCase {
    func testStructuredAndLegacyDefinitionsKeepMeaningSeparateFromMetadata() throws {
        let markdown = "## tugs\n\n原形：tug\n\n1. 用力拉；拽。\n\n### 例句\nHe tugs her sleeve."
        func output(_ gloss: String) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: ["gloss": gloss, "phonetic": "/tʌɡz/", "definition": markdown]), as: UTF8.self) }
        let parsed = try AIDictionaryEntry.parse(output("轻拽"))
        XCTAssertEqual(parsed.definition, markdown); XCTAssertEqual(parsed.gloss, "轻拽"); XCTAssertEqual(parsed.phonetic, "/tʌɡz/")
        XCTAssertEqual(try AIDictionaryEntry.parse("```json\n" + output("轻拽") + "\n```"), parsed)
        for gloss in ["", "原形：tug", "pull"] { XCTAssertEqual(try AIDictionaryEntry.parse(output(gloss)).gloss, "") }
        let legacy = "原形：tug\n词性：动词，第三人称单数\n音标：/tʌɡz/\n释义：用力拉；拽"
        XCTAssertEqual(try AIDictionaryEntry.parse(legacy).gloss, "用力拉；拽")
        XCTAssertEqual(DictionaryGloss.extract(legacy.replacingOccurrences(of: "\n", with: " ")).meaning, "用力拉；拽")
        XCTAssertEqual(DictionaryGloss.extract("## tugs\n\n**原形**：tug\n**词性**：动词\n1. 拉扯；拽\n2. 拖船").meaning, "拉扯；拽")
        XCTAssertEqual(DictionaryGloss.extract("## tugs\n### 原形\ntug\n### 词性\n动词\n### 释义\n拉扯").meaning, "拉扯")
        XCTAssertEqual(DictionaryGloss.extract("基本释义：用力拉；拽\n**简短释义**：轻轻拽\n### 语境义\n拉一下衣袖").meaning, "轻轻拽")
        XCTAssertEqual(DictionaryGloss.extract("基本释义：用力拉；拽\n### 语境义\n拉一下衣袖").meaning, "拉一下衣袖")
        XCTAssertEqual(DictionaryGloss.extract("原形：tug\n词性：动词\n音标：/tʌɡz/").meaning, "")
        XCTAssertEqual(DictionaryGloss.extract("原形").meaning, "原形")
        XCTAssertEqual(try AIDictionaryEntry.parse(#"{"markdown":"释义：拉拽"}"#).gloss, "拉拽")
        XCTAssertEqual(try AIDictionaryEntry.parse(#"{"definition":" ","markdown":"释义：拉拽"}"#).definition, "释义：拉拽")
        XCTAssertThrowsError(try AIDictionaryEntry.parse("  "))
        XCTAssertThrowsError(try AIDictionaryEntry.parse(#"{"definition":{},"gloss":null}"#))
        XCTAssertThrowsError(try AIDictionaryEntry.parse(String(repeating: "x", count: 64_001)))
    }
    func testLookupContextRespectsReadingBoundaryAndExplicitSelection() throws {
        let chapter = Chapter(id: 2, title: "Story", text: "Before 😊 He tugs her sleeve. UNREAD ENDING")
        let offset = (chapter.text as NSString).range(of: "tugs").location
        let source = SourcePassage(bookID: UUID(), chapter: chapter, offset: offset, text: "tugs")
        let context = try AIDictionaryEntry.context(source: source, chapter: chapter, through: .init(chapter: 2, offset: offset + 4))
        XCTAssertEqual(context, "Before 😊 He tugs"); XCTAssertFalse(context.contains("UNREAD"))
        XCTAssertEqual(try AIDictionaryEntry.context(source: source, chapter: chapter, through: .init()), context)
        XCTAssertThrowsError(try AIDictionaryEntry.context(source: source, chapter: Chapter(id: 2, title: "Story", text: "Changed"), through: .init()))
        let messages = try AIDictionaryEntry.messages(word: " tugs ", context: context)
        XCTAssertEqual(messages.last?.content, "字词：tugs\n语境：Before 😊 He tugs")
        XCTAssertFalse(messages.last!.content.contains("UNREAD"))
        for word in ["", "bad\u{0}word", String(repeating: "x", count: 81)] { XCTAssertThrowsError(try AIDictionaryEntry.messages(word: word, context: "")) }
        XCTAssertEqual(try AIDictionaryEntry.messages(word: "字", context: String(repeating: "文", count: 1000)).last?.content.filter { $0 == "文" }.count, 600)
    }
}
