import Foundation
import MoReadCore
import ReadiumShared

extension EPUBSourceBlock {
    static func script(blocks: [Self], selecting: Bool, translations: [ParagraphTranslation]? = nil, restoring: Locator? = nil, typography: ReaderTypography? = nil, vocabulary: [String: DictionaryGloss] = [:]) throws -> String {
        guard let url = Bundle.main.url(forResource: "EPUBSourceMap", withExtension: "js") else { throw MoReadError.invalid("无法读取 EPUB 正文定位组件。") }
        let script = try String(contentsOf: url, encoding: .utf8)
        // Fixed-layout Readium spreads embed evaluated code in a template literal.
        let json = String(decoding: try JSONEncoder().encode(blocks), as: UTF8.self).replacingOccurrences(of: "$", with: "\\u0024")
        let rows = String(decoding: try JSONEncoder().encode(translations), as: UTF8.self).replacingOccurrences(of: "$", with: "\\u0024")
        let target = try restoring.map { String(decoding: try JSONSerialization.data(withJSONObject: $0.json), as: UTF8.self).replacingOccurrences(of: "$", with: "\\u0024") } ?? "null"
        var english = "null"
        if let typography {
            let words = Set(blocks.flatMap { EnglishReading.words(in: $0.text).map(\.word) })
            let meanings = vocabulary.filter { words.contains($0.key) }.mapValues { [$0.meaning, $0.phonetic] }
            let config: [String: Any] = ["bionic": typography.englishBionic == true, "mode": typography.englishLearning == true ? (typography.wordAnnotationMode ?? .inline).rawValue : "off", "words": meanings]
            english = String(decoding: try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]), as: UTF8.self).replacingOccurrences(of: "$", with: "\\u0024")
        }
        return "(\(script))(\(json), \(selecting), \(rows), \(target), \(english));"
    }
}
