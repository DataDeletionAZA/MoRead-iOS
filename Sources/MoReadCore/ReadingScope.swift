import Foundation

public struct ReadingScope: Codable, Hashable, Sendable {
    public let end: ReadingPosition
    public init(through position: ReadingPosition) { end = position }
    public static let wholeBook = ReadingScope(through: .init(chapter: Int.max, offset: Int.max))
    public func intersect(_ other: Self) -> Self { Self(through: min(end, other.end)) }
    public func readableText(_ chapter: Chapter) -> String {
        guard chapter.id >= 0, chapter.id <= end.chapter else { return "" }
        return chapter.id < end.chapter ? chapter.text : TextBoundary.prefix(chapter.text, end: end.offset)
    }
    public func allows(chapter: Int, range: NSRange) -> Bool {
        guard chapter >= 0, range.location >= 0, range.length > 0,
              range.location <= Int.max - range.length else { return false }
        return chapter < end.chapter || (chapter == end.chapter && range.location + range.length <= end.offset)
    }
}

public struct SourcePassage: Codable, Identifiable, Hashable, Sendable {
    public var id: String { "\(bookID):\(chapter):\(offset):\(revision)" }
    public var bookID: UUID
    public var chapter: Int
    public var offset: Int
    public var text: String
    public var revision: String
    public var epubLocator: Data?
    public init(bookID: UUID, chapter: Chapter, offset: Int, text: String) {
        self.bookID = bookID; self.chapter = chapter.id; self.offset = offset
        self.text = text; revision = chapter.revision
    }
    public func isValid(in source: Chapter, scope: ReadingScope) -> Bool {
        let range = NSRange(location: offset, length: text.utf16.count)
        guard chapter == source.id, revision == source.revision,
              scope.allows(chapter: chapter, range: range),
              offset <= source.text.utf16.count, range.length <= source.text.utf16.count - offset,
              TextBoundary.floor(offset, in: source.text) == offset else { return false }
        return (source.text as NSString).substring(with: range) == text
    }
}

public enum BookSearch {
    public static func find(_ query: String, in chapter: Chapter, bookID: UUID, scope: ReadingScope, limit: Int = 40) -> [SourcePassage] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, limit > 0 else { return [] }
        let text = scope.readableText(chapter) as NSString
        var offset = 0
        var passages: [SourcePassage] = []
        while offset < text.length, passages.count < limit {
            let found = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: offset, length: text.length - offset))
            if found.location == NSNotFound { break }
            let start = TextBoundary.floor(max(0, found.location - 100), in: text as String)
            let end = TextBoundary.floor(min(text.length, found.location + found.length + 180), in: text as String)
            passages.append(SourcePassage(bookID: bookID, chapter: chapter, offset: start, text: text.substring(with: NSRange(location: start, length: end - start))))
            offset = found.location + max(1, found.length)
        }
        return passages
    }
}
