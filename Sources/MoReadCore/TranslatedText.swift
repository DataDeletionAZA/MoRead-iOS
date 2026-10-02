import Foundation

public struct TranslatedText: Equatable, Sendable {
    public struct Insertion: Equatable, Sendable {
        public let sourceRange: NSRange
        public let displayRange: NSRange
        public var textRange: NSRange { NSRange(location: displayRange.location + 1, length: displayRange.length - 1) }
    }
    public let source: String
    public let text: String
    public let insertions: [Insertion]
    public init(source: String, translations: [ParagraphTranslation] = [], visible: Bool = true) {
        self.source = source
        let original = source as NSString
        var parts: [String] = [], insertions: [Insertion] = [], cursor = 0, added = 0
        if visible {
            for row in translations.sorted(by: { $0.start < $1.start }) where !row.hidden {
                guard row.start >= cursor, row.matches(source), (try? row.validate()) != nil else { continue }
                parts.append(original.substring(with: NSRange(location: cursor, length: row.end - cursor)))
                let value = "\n" + row.chinese
                insertions.append(.init(sourceRange: NSRange(location: row.start, length: row.end - row.start), displayRange: NSRange(location: row.end + added, length: value.utf16.count)))
                parts.append(value); added += value.utf16.count; cursor = row.end
            }
        }
        parts.append(original.substring(from: cursor))
        text = parts.joined(); self.insertions = insertions
    }
    public func displayOffset(forSource offset: Int, afterInsertion: Bool = true) -> Int {
        let safe = TextBoundary.floor(offset, in: source)
        return safe + insertions.lazy.filter {
            NSMaxRange($0.sourceRange) < safe || (afterInsertion && NSMaxRange($0.sourceRange) == safe)
        }.reduce(0) { $0 + $1.displayRange.length }
    }
    public func sourceOffset(forDisplay offset: Int, trailing: Bool = false) -> Int {
        let safe = TextBoundary.floor(offset, in: text)
        var added = 0
        for insertion in insertions {
            if safe < insertion.displayRange.location { break }
            if safe < NSMaxRange(insertion.displayRange) { return trailing ? NSMaxRange(insertion.sourceRange) : insertion.sourceRange.location }
            added += insertion.displayRange.length
        }
        return TextBoundary.floor(safe - added, in: source)
    }
    public func sourceRange(forDisplay range: NSRange) -> NSRange? {
        guard valid(range, length: text.utf16.count) else { return nil }
        let start = sourceOffset(forDisplay: range.location)
        let end = range.length == 0 ? start : sourceOffset(forDisplay: NSMaxRange(range), trailing: true)
        return NSRange(location: start, length: max(0, end - start))
    }
    public func containsTranslation(in range: NSRange) -> Bool {
        valid(range, length: text.utf16.count) && insertions.contains { NSIntersectionRange($0.displayRange, range).length > 0 }
    }
    public func displayRanges(forSource range: NSRange) -> [NSRange] {
        guard valid(range, length: source.utf16.count), range.length > 0 else { return [] }
        let end = NSMaxRange(range)
        let cuts = [range.location] + insertions.map { NSMaxRange($0.sourceRange) }.filter { $0 > range.location && $0 < end } + [end]
        return zip(cuts, cuts.dropFirst()).compactMap { lower, upper in
            let start = displayOffset(forSource: lower), end = displayOffset(forSource: upper, afterInsertion: false)
            return end > start ? NSRange(location: start, length: end - start) : nil
        }
    }
    private func valid(_ range: NSRange, length: Int) -> Bool {
        range.location >= 0 && range.length >= 0 && range.location <= length && range.length <= length - range.location
    }
}
