import XCTest
@testable import MoReadCore

final class ReaderSyntaxTests: XCTestCase {
    func testReadingTypographyRulesCompatibilityAndBackup() async throws {
        var rule = ReaderSyntaxRule(); rule.name = "对白"; rule.includeDelimiters = false
        rule.css = "color: linear-gradient(to right, #f60, #36c); font-weight: bold;"
        var typography = ReaderTypography(); typography.syntaxEnabled = true; typography.syntaxRules = [rule]
        typography.customFontID = UUID(); typography.englishBionic = true; typography.firstLineIndent = 2
        XCTAssertEqual(ReaderTypography(data: typography.encoded()), typography)
        var invalid = rule; invalid.id = UUID(); invalid.mode = .regex; invalid.pattern = "["
        var malformed = typography; malformed.syntaxRules = [rule, rule, invalid]
        XCTAssertEqual(ReaderTypography(data: try JSONEncoder().encode(malformed)).syntaxRules, [rule])
        malformed.syntaxRules = (0..<70).map { _ in ReaderSyntaxRule() }
        XCTAssertEqual(ReaderTypography(data: malformed.encoded()).syntaxRules?.count, 64)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: typography.encoded()) as? [String: Any])
        legacy.removeValue(forKey: "syntaxEnabled"); legacy.removeValue(forKey: "syntaxRules")
        let old = ReaderTypography(data: try JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(old.syntaxRules); XCTAssertNil(old.syntaxEnabled)
        XCTAssertEqual(old.customFontID, typography.customFontID); XCTAssertEqual(old.firstLineIndent, 2)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root.appendingPathComponent("library"))
        let preferences = store.root.appendingPathComponent("reader-settings.plist")
        let data = try PropertyListSerialization.data(fromPropertyList: ["reader.typography": typography.encoded()], format: .binary, options: 0)
        try data.write(to: preferences)
        let file = root.appendingPathComponent("settings.zip")
        _ = try await BackupArchive.create(root: store.root, output: file)
        try Data().write(to: preferences)
        let backup = try await BackupArchive.prepare(file, beside: store.root); try BackupArchive.activate(backup, replacing: store.root)
        let values = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: preferences), format: nil) as? [String: Data])
        XCTAssertEqual(ReaderTypography(data: try XCTUnwrap(values["reader.typography"])), typography)
        var card = ReviewCardTemplate(); card.syntaxEnabled = true; card.syntaxRules = [rule]
        try card.validate(); XCTAssertEqual(try JSONDecoder().decode(ReviewCardTemplate.self, from: JSONEncoder().encode(card)).syntaxRules, typography.syntaxRules)
    }
    func testParagraphRulesKeepWholeChapterOffsetsAndDoNotCrossParagraphs() throws {
        var rule = ReaderSyntaxRule(); rule.includeDelimiters = false
        let text = "😀「灯塔」\r\n「未闭合\n下一段」\n「书店」"
        let matches = try ReaderSyntax.paragraphMatches(text, rules: [rule])
        let body = text as NSString
        XCTAssertEqual(matches.map { body.substring(with: $0.range) }, ["灯塔", "书店"])
        XCTAssertEqual(matches.map(\.range), [body.range(of: "灯塔"), body.range(of: "书店")])
        let long = String(repeating: "「灯塔」\n", count: 12000)
        XCTAssertGreaterThan(long.utf16.count, 50000)
        let many = try ReaderSyntax.paragraphMatches(long, rules: [rule])
        XCTAssertEqual(many.count, 12000)
        XCTAssertEqual(many.last?.range, NSRange(location: long.utf16.count - 4, length: 2))
        rule.enabled = false
        XCTAssertTrue(try ReaderSyntax.paragraphMatches(long, rules: [rule]).isEmpty)
    }
    func testDelimitedEmojiPriorityAndGlyphOnlyDelimiters() throws {
        let text = "「灯塔😀」与「书店」"
        var quote = ReaderSyntaxRule(); quote.includeDelimiters = false; quote.bold = true
        var word = ReaderSyntaxRule(); word.mode = .regex; word.pattern = "灯塔😀|书店"
        let matches = try ReaderSyntax.matches(text, rules: [quote, word])
        XCTAssertEqual(matches.count, 6)
        XCTAssertTrue(matches.allSatisfy { $0.ruleID == quote.id })
        XCTAssertEqual(matches.filter { !$0.glyphsOnly }.map { (text as NSString).substring(with: $0.range) }, ["灯塔😀", "书店"])
        let reordered = try ReaderSyntax.matches(text, rules: [word, quote])
        XCTAssertEqual(reordered.filter { !$0.glyphsOnly }.map(\.ruleID), [word.id, word.id])
        quote.bold = false
        XCTAssertEqual(try ReaderSyntax.matches(text, rules: [quote]).count, 2)
        quote.includeDelimiters = true
        XCTAssertEqual(try ReaderSyntax.matches(text, rules: [quote]).map { (text as NSString).substring(with: $0.range) }, ["「灯塔😀」", "「书店」"])
        quote.enabled = false; XCTAssertTrue(try ReaderSyntax.matches(text, rules: [quote]).isEmpty)
        quote.enabled = true; XCTAssertTrue(try ReaderSyntax.matches("「未闭合", rules: [quote]).isEmpty)
    }
    func testRegexCaseMultilineInvalidAndTimeout() throws {
        var rule = ReaderSyntaxRule(); rule.mode = .regex; rule.pattern = "^light"; rule.ignoreCase = true
        XCTAssertEqual(try ReaderSyntax.matches("Light\nlight\n灯塔", rules: [rule]).map(\.range), [NSRange(location: 0, length: 5), NSRange(location: 6, length: 5)])
        rule.pattern = "^"; XCTAssertTrue(try ReaderSyntax.matches("x", rules: [rule]).isEmpty)
        rule.pattern = "["; XCTAssertThrowsError(try rule.validate())
        rule.pattern = "e"; XCTAssertThrowsError(try ReaderSyntax.matches("e\u{301}", rules: [rule]))
        rule.pattern = "(a+)+$"
        let start = Date()
        XCTAssertThrowsError(try ReaderSyntax.matches(String(repeating: "a", count: 25000) + "!", rules: [rule]))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
    func testStyleOverridesLibraryBackupAndOldTemplates() async throws {
        var rule = ReaderSyntaxRule(); rule.background = 0xFFEEDD; rule.font = .serif
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
