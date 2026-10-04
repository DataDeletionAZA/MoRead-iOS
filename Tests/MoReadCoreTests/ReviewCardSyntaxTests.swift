import XCTest
@testable import MoReadCore

final class ReviewCardSyntaxTests: XCTestCase {
    func testDelimitedEmojiPriorityAndGlyphOnlyDelimiters() throws {
        let text = "「灯塔😀」与「书店」"
        var quote = ReviewCardSyntaxRule(); quote.includeDelimiters = false; quote.bold = true
        var word = ReviewCardSyntaxRule(); word.mode = .regex; word.pattern = "灯塔😀|书店"
        let matches = try ReviewCardSyntax.matches(text, rules: [quote, word])
        XCTAssertEqual(matches.count, 6)
        XCTAssertTrue(matches.allSatisfy { $0.ruleID == quote.id })
        XCTAssertEqual(matches.filter { !$0.glyphsOnly }.map { (text as NSString).substring(with: $0.range) }, ["灯塔😀", "书店"])
        let reordered = try ReviewCardSyntax.matches(text, rules: [word, quote])
        XCTAssertEqual(reordered.filter { !$0.glyphsOnly }.map(\.ruleID), [word.id, word.id])
        quote.bold = false
        XCTAssertEqual(try ReviewCardSyntax.matches(text, rules: [quote]).count, 2)
        quote.includeDelimiters = true
        XCTAssertEqual(try ReviewCardSyntax.matches(text, rules: [quote]).map { (text as NSString).substring(with: $0.range) }, ["「灯塔😀」", "「书店」"])
        quote.enabled = false; XCTAssertTrue(try ReviewCardSyntax.matches(text, rules: [quote]).isEmpty)
        quote.enabled = true; XCTAssertTrue(try ReviewCardSyntax.matches("「未闭合", rules: [quote]).isEmpty)
    }
    func testRegexCaseMultilineInvalidAndTimeout() throws {
        var rule = ReviewCardSyntaxRule(); rule.mode = .regex; rule.pattern = "^light"; rule.ignoreCase = true
        XCTAssertEqual(try ReviewCardSyntax.matches("Light\nlight\n灯塔", rules: [rule]).map(\.range), [NSRange(location: 0, length: 5), NSRange(location: 6, length: 5)])
        rule.pattern = "^"; XCTAssertTrue(try ReviewCardSyntax.matches("x", rules: [rule]).isEmpty)
        rule.pattern = "["; XCTAssertThrowsError(try rule.validate())
        rule.pattern = "e"; XCTAssertThrowsError(try ReviewCardSyntax.matches("e\u{301}", rules: [rule]))
        rule.pattern = "(a+)+$"
        let start = Date()
        XCTAssertThrowsError(try ReviewCardSyntax.matches(String(repeating: "a", count: 25000) + "!", rules: [rule]))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
    func testStyleOverridesLibraryBackupAndOldTemplates() async throws {
        var rule = ReviewCardSyntaxRule(); rule.background = 0xFFEEDD; rule.font = .serif
        rule.css = "background: linear-gradient(90deg, red, white); background-clip: text; color: #123456; font-style: italic;"
        let style = try rule.style()
        XCTAssertNotNil(style.textGradient); XCTAssertNil(style.background); XCTAssertEqual(style.color?.rgba, 0x123456FF)
        XCTAssertEqual(style.font, .serif); XCTAssertEqual(style.italic, true)
        rule.css = "padding: 1em"; XCTAssertThrowsError(try rule.validate()); rule.css = "color: #123456;"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root.appendingPathComponent("library")), library = ReviewCardLibrary(root: store.root)
        var template = ReviewCardTemplate(); template.syntaxEnabled = true; template.syntaxRules = [rule]
        try library.save(template)
        let file = root.appendingPathComponent("rules.zip")
        _ = try await BackupArchive.create(root: store.root, output: file)
        try library.remove(template.id)
        let backup = try await BackupArchive.prepare(file, beside: store.root); try BackupArchive.activate(backup, replacing: store.root)
        XCTAssertEqual(try library.templates(), [template])
        template.syntaxRules = [rule, rule]; XCTAssertThrowsError(try library.save(template))
        let old = try JSONEncoder().encode(ReviewCardTemplate())
        XCTAssertNil(try JSONDecoder().decode(ReviewCardTemplate.self, from: old).syntaxRules)
    }
}
