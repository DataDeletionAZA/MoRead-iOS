import Foundation
import CryptoKit

public struct ReadingPosition: Codable, Hashable, Comparable, Sendable {
    public var chapter: Int
    public var offset: Int
    public init(chapter: Int = 0, offset: Int = 0) {
        self.chapter = max(0, chapter)
        self.offset = max(0, offset)
    }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.chapter == rhs.chapter ? lhs.offset < rhs.offset : lhs.chapter < rhs.chapter
    }
}

public struct Chapter: Codable, Identifiable, Hashable, Sendable {
    public var id: Int
    public var title: String
    public var text: String
    public init(id: Int, title: String, text: String) {
        self.id = id; self.title = title; self.text = text
    }
    public var revision: String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
}

public struct ChapterInfo: Codable, Identifiable, Hashable, Sendable {
    public var id: Int
    public var title: String
    public var length: Int
    public var revision: String
    public init(_ chapter: Chapter) {
        id = chapter.id; title = chapter.title; length = chapter.text.utf16.count; revision = chapter.revision
    }
}

public struct Book: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var author: String
    public var format: String
    public var chapters: [ChapterInfo]
    public var position: ReadingPosition
    public var readThrough: ReadingPosition
    public var importedAt: Date
    public var lastOpened: Date?
    public var pinned: Bool
    public var group: String
    public var tags: [String]
    public var state: String
    public var removed: Bool
    public var epubLocator: Data?
    public var bodyCleared: Bool?
    public var hasBody: Bool { bodyCleared != true }
    public init(id: UUID = UUID(), title: String, author: String = "", format: String = "txt", chapters: [Chapter]) {
        self.id = id; self.title = title; self.author = author; self.format = format
        self.chapters = chapters.map(ChapterInfo.init)
        position = .init(); readThrough = .init(); importedAt = Date()
        pinned = false; group = ""; tags = []; state = "未读"; removed = false
    }
    public var progress: Double {
        let total = chapters.reduce(0) { $0 + $1.length }
        guard total > 0 else { return 0 }
        let before = chapters.filter { $0.id < position.chapter }.reduce(0) { $0 + $1.length }
        return min(1, Double(before + position.offset) / Double(total))
    }
    public mutating func record(position: ReadingPosition, visibleEnd: ReadingPosition) {
        guard chapters.indices.contains(position.chapter), chapters.indices.contains(visibleEnd.chapter) else { return }
        self.position = ReadingPosition(chapter: position.chapter, offset: min(position.offset, chapters[position.chapter].length))
        let end = ReadingPosition(chapter: visibleEnd.chapter, offset: min(visibleEnd.offset, chapters[visibleEnd.chapter].length))
        readThrough = max(readThrough, end)
        lastOpened = Date()
        if state == "未读" { state = "在读" }
    }
}

public enum MoReadError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

public enum TextBoundary {
    // All persisted anchors use UTF-16, matching UIKit and the Android source.
    public static func floor(_ offset: Int, in text: String) -> Int {
        let value = text as NSString
        let end = min(max(0, offset), value.length)
        if end > 0, end < value.length,
           (0xDC00...0xDFFF).contains(value.character(at: end)),
           (0xD800...0xDBFF).contains(value.character(at: end - 1)) { return end - 1 }
        return end
    }
    public static func prefix(_ text: String, end: Int) -> String {
        (text as NSString).substring(to: floor(end, in: text))
    }
}
