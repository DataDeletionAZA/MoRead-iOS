import XCTest
@testable import MoReadCore

final class EnglishReadingTests: XCTestCase {
    func testSourceOffsetsVocabularyFilteringAndSettingsCompatibility() throws {
        let text = "雨😊 After can’t well-known THE " + String(repeating: "x", count: 81)
        let runs = EnglishReading.words(in: text)
        XCTAssertEqual(runs.map(\.word), ["after", "can't", "well-known", "the"])
        XCTAssertEqual(runs.map { (text as NSString).substring(with: $0.range) }, ["After", "can’t", "well-known", "THE"])
        XCTAssertEqual(runs.map { (text as NSString).substring(with: $0.prefix) }, ["Aft", "can", "well-", "TH"])
        XCTAssertEqual(runs.first?.range.location, 4)
        var learned = VocabularyWord(word: "THE", definition: "定冠词", gloss: "这一个"); learned.learned = true
        let words = EnglishReading.unlearned([learned, .init(word: "Can’t", definition: "不能", gloss: "不能", phonetic: "/kɑːnt/"), .init(word: "中文", definition: "释义"), .init(word: "two words", definition: "词组")])
        XCTAssertEqual(Set(words.keys), ["can't"]); XCTAssertEqual(words["can't"]?.phonetic, "/kɑːnt/")
        let defaults = ReaderTypography()
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: defaults.encoded()) as? [String: Any])
        for key in ["englishLearning", "englishBionic", "wordAnnotationMode"] { old.removeValue(forKey: key) }
        XCTAssertEqual(ReaderTypography(data: try JSONSerialization.data(withJSONObject: old)), defaults)
        var enabled = defaults; enabled.englishLearning = true; enabled.englishBionic = true; enabled.wordAnnotationMode = .popup
        XCTAssertEqual(ReaderTypography(data: enabled.encoded()), enabled)
    }
}
