import Foundation

public enum WordAnnotationMode: String, Codable, CaseIterable, Sendable {
    case inline, popup, off
    public var label: String { switch self { case .inline: "直接显示"; case .popup: "划线弹窗"; case .off: "关闭标注" } }
}

public struct EnglishWordRun: Equatable, Sendable {
    public let range: NSRange
    public let prefix: NSRange
    public let word: String
}

public enum EnglishReading {
    private static let pattern = try! NSRegularExpression(pattern: #"[A-Za-z]+(?:['’\-][A-Za-z]+)*"#)
    public static func words(in text: String) -> [EnglishWordRun] {
        let source = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: source.length)).compactMap { match in
            guard match.range.length <= 80 else { return nil }
            let value = source.substring(with: match.range)
            return EnglishWordRun(range: match.range, prefix: NSRange(location: match.range.location, length: max(1, (match.range.length + 1) / 2)), word: VocabularyWord.normalize(value))
        }
    }
    public static func unlearned(_ vocabulary: [VocabularyWord]) -> [String: DictionaryGloss] {
        Dictionary(vocabulary.filter { !$0.learned && $0.word.range(of: #"^[a-z]+(?:['\-][a-z]+)*$"#, options: .regularExpression) != nil }.map {
            ($0.word, DictionaryGloss(meaning: $0.gloss, phonetic: $0.phonetic))
        }, uniquingKeysWith: { _, last in last })
    }
}
