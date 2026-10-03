import Foundation
import NaturalLanguage

public struct SpeechSegment: Equatable, Sendable {
    public let offset: Int
    public let end: Int
    public let text: String
    public let transformed: Bool
    init(offset: Int, end: Int, text: String, transformed: Bool = false) {
        self.offset = offset; self.end = end; self.text = text; self.transformed = transformed
    }
    public func purified(rules: [TextReplacementRule]) throws -> Self {
        guard rules.contains(where: { $0.enabled && $0.forListeningOnly }) else { return self }
        let cleaned = try TextCleanup.apply(text, rules: rules, forListening: true).text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.utf16.count <= 4096 else { throw MoReadError.invalid("听书净化后这一句超过 4096 字，请缩短替换内容。") }
        return Self(offset: offset, end: end, text: cleaned, transformed: transformed || cleaned != text)
    }
    public func sourceRange(forSpokenRange range: NSRange) -> NSRange {
        if transformed { return NSRange(location: offset, length: end - offset) }
        let start = TextBoundary.floor(range.location, in: text)
        let length = min(max(0, range.length), text.utf16.count - start)
        let finish = TextBoundary.floor(start + length, in: text)
        return NSRange(location: offset + start, length: finish - start)
    }
}

public enum SpeechText {
    public static func next(in text: String, from offset: Int, maximumLength: Int = 1000) -> SpeechSegment? {
        let source = text as NSString
        var start = TextBoundary.floor(offset, in: text)
        while start < source.length, let scalar = UnicodeScalar(source.character(at: start)), CharacterSet.whitespacesAndNewlines.contains(scalar) { start += 1 }
        guard start < source.length else { return nil }
        let end = TextBoundary.floor(min(start + min(4096, max(2, maximumLength)), source.length), in: text)
        let part = source.substring(with: NSRange(location: start, length: end - start))
        let tokenizer = NLTokenizer(unit: .sentence); tokenizer.string = part
        var sentence = part
        tokenizer.enumerateTokens(in: part.startIndex..<part.endIndex) { range, _ in sentence = String(part[..<range.upperBound]); return false }
        return SpeechSegment(offset: start, end: start + sentence.utf16.count, text: sentence)
    }
}
