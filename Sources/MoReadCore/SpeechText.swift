import Foundation
import NaturalLanguage

public struct SpeechSegment: Equatable, Sendable {
    public let offset: Int
    public let end: Int
    public let text: String
}

public enum SpeechText {
    public static func next(in text: String, from offset: Int) -> SpeechSegment? {
        let source = text as NSString
        var start = TextBoundary.floor(offset, in: text)
        while start < source.length, let scalar = UnicodeScalar(source.character(at: start)), CharacterSet.whitespacesAndNewlines.contains(scalar) { start += 1 }
        guard start < source.length else { return nil }
        let end = TextBoundary.floor(min(start + 1000, source.length), in: text)
        let part = source.substring(with: NSRange(location: start, length: end - start))
        let tokenizer = NLTokenizer(unit: .sentence); tokenizer.string = part
        var sentence = part
        tokenizer.enumerateTokens(in: part.startIndex..<part.endIndex) { range, _ in sentence = String(part[..<range.upperBound]); return false }
        return SpeechSegment(offset: start, end: start + sentence.utf16.count, text: sentence)
    }
}
