import Foundation

public enum ChineseConversionMode: String, Codable, CaseIterable, Sendable {
    case off, tw2sp, s2twp
    public var label: String {
        switch self { case .off: return "显示原文"; case .tw2sp: return "简体（大陆用语）"; case .s2twp: return "繁体（台湾用语）" }
    }
}

public struct ChineseTextConversion: Equatable, Sendable {
    public let source: String
    public let text: String
    struct Edit: Equatable, Sendable { let source: NSRange; let display: NSRange }
    let stages: [[Edit]]

    public init(_ source: String, mode: ChineseConversionMode) throws {
        self.source = source
        if mode == .off || source.isEmpty { text = source; stages = []; return }
        try Task.checkCancellation()
        let dictionaries = try ChineseConversionDictionaries.shared.get()
        let chain = mode == .s2twp ? dictionaries.traditional : dictionaries.simplified
        var units = Array(source.utf16), stages: [[Edit]] = []
        for dictionary in chain {
            let converted = try dictionary.convert(units)
            units = converted.units; stages.append(converted.edits)
        }
        self.text = String(decoding: units, as: UTF16.self); self.stages = stages
    }
    // A partial selection inside a changed phrase includes that phrase's complete source.
    private func map(_ offset: Int, edits: [Edit], reverse: Bool, trailing: Bool) -> Int {
        var low = 0, high = edits.count
        while low < high {
            let middle = (low + high) / 2, range = reverse ? edits[middle].display : edits[middle].source
            if range.location < offset { low = middle + 1 } else { high = middle }
        }
        guard low > 0 else { return offset }
        let edit = edits[low - 1], from = reverse ? edit.display : edit.source, to = reverse ? edit.source : edit.display
        if offset < NSMaxRange(from) { return trailing ? NSMaxRange(to) : to.location }
        return offset + NSMaxRange(to) - NSMaxRange(from)
    }
    public func displayOffset(forSource offset: Int, trailing: Bool = false) -> Int {
        let safe = TextBoundary.floor(offset, in: source)
        return TextBoundary.floor(stages.reduce(safe) { map($0, edits: $1, reverse: false, trailing: trailing) }, in: text)
    }
    public func sourceOffset(forDisplay offset: Int, trailing: Bool = false) -> Int {
        let safe = TextBoundary.floor(offset, in: text)
        return TextBoundary.floor(stages.reversed().reduce(safe) { map($0, edits: $1, reverse: true, trailing: trailing) }, in: source)
    }
    public func sourceRange(forDisplay range: NSRange) -> NSRange? {
        guard range.location >= 0, range.length >= 0, range.location <= text.utf16.count, range.length <= text.utf16.count - range.location else { return nil }
        let start = sourceOffset(forDisplay: range.location), end = range.length == 0 ? start : sourceOffset(forDisplay: NSMaxRange(range), trailing: true)
        return NSRange(location: start, length: max(0, end - start))
    }
}

private struct ChineseConversionDictionaries {
    struct Dictionary {
        let pairs: [[UInt16]: [UInt16]]
        let lengths: [UInt16: [Int]]
        init(_ names: [String]) throws {
            var pairs: [[UInt16]: [UInt16]] = [:], lengths: [UInt16: Set<Int>] = [:]
            for name in names {
                guard let url = Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "ChineseConversion") else { throw MoReadError.invalid("繁简转换词库缺失，请重新安装应用。") }
                for line in try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
                    let columns = line.split(separator: "\t", maxSplits: 1)
                    guard columns.count == 2, let value = columns[1].split(separator: " ").first else { throw MoReadError.invalid("繁简转换词库无法读取。") }
                    let key = Array(columns[0].utf16)
                    if pairs[key] == nil { pairs[key] = Array(value.utf16); lengths[key[0], default: []].insert(key.count) }
                }
            }
            self.pairs = pairs; self.lengths = lengths.mapValues { $0.sorted(by: >) }
        }
        func convert(_ input: [UInt16]) throws -> (units: [UInt16], edits: [ChineseTextConversion.Edit]) {
            var output: [UInt16] = [], edits: [ChineseTextConversion.Edit] = [], index = 0, end = 0
            output.reserveCapacity(input.count)
            while index < input.count {
                if index & 1023 == 0 { try Task.checkCancellation() }
                if index >= end {
                    end = index
                    repeat { end += 1 } while end < input.count && !ChineseConversionDictionaries.delimiters.contains(input[end - 1])
                }
                var replacement: [UInt16]?, length = 0
                for count in lengths[input[index]] ?? [] where count <= end - index {
                    if let value = pairs[Array(input[index..<(index + count)])] { replacement = value; length = count; break }
                }
                if let replacement {
                    if !input[index..<(index + length)].elementsEqual(replacement) {
                        edits.append(.init(source: NSRange(location: index, length: length), display: NSRange(location: output.count, length: replacement.count)))
                    }
                    output.append(contentsOf: replacement); index += length
                } else { output.append(input[index]); index += 1 }
            }
            try Task.checkCancellation(); return (output, edits)
        }
    }
    let traditional: [Dictionary]
    let simplified: [Dictionary]
    static let shared: Result<Self, Error> = Result {
        Self(traditional: try [Dictionary(["STPhrases", "STCharacters"]), Dictionary(["TWPhrases", "TWVariantsPhrases", "TWVariants"])],
             simplified: try [Dictionary(["TWPhrasesRev", "TWVariantsRevPhrases", "TWVariantsRev"]), Dictionary(["TSPhrases", "TSCharacters"])])
    }
    static let delimiters = Set(" \t\n\r!\"#$%&'()*+,-./:;<=>?@[\\]^_{|}~＝、。﹁﹂—－（）《》〈〉？！…／＼︒︑︔︓︿﹀︹︺︙︐［﹇］﹈︕︖︰︳︴︽︾︵︶｛︷｝︸﹃﹄【︻】︼　～．，；：".utf16)
}

extension BookSearch {
    public static func find(_ query: String, in chapter: Chapter, bookID: UUID, scope: ReadingScope, conversion: ChineseConversionMode, limit: Int = 40) throws -> [SourcePassage] {
        if conversion == .off { return find(query, in: chapter, bookID: bookID, scope: scope, limit: limit) }
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, limit > 0 else { return [] }
        let visible = scope.readableText(chapter), converted = try ChineseTextConversion(visible, mode: conversion)
        let needle = try ChineseTextConversion(query, mode: conversion).text, text = converted.text as NSString, source = visible as NSString
        var offset = 0, passages: [SourcePassage] = []
        while offset < text.length, passages.count < limit {
            try Task.checkCancellation()
            let found = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: offset, length: text.length - offset))
            guard found.location != NSNotFound else { break }
            let start = TextBoundary.floor(max(0, found.location - 100), in: converted.text)
            let end = TextBoundary.floor(min(text.length, NSMaxRange(found) + 180), in: converted.text)
            if let range = converted.sourceRange(forDisplay: NSRange(location: start, length: end - start)), range.length > 0 {
                let passage = SourcePassage(bookID: bookID, chapter: chapter, offset: range.location, text: source.substring(with: range))
                if passages.last?.id != passage.id { passages.append(passage) }
            }
            offset = NSMaxRange(found)
        }
        return passages
    }
}
