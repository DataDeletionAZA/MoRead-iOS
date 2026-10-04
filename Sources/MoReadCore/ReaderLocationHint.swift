import Foundation

public struct ReaderLocationHint: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let passage: SourcePassage
    public private(set) var seen = false
    public init(passage: SourcePassage) { self.passage = passage }
    public mutating func observe(_ visible: SourcePassage?) {
        guard !seen, let visible, visible.bookID == passage.bookID, visible.chapter == passage.chapter,
              visible.revision == passage.revision, visible.offset >= 0, passage.offset >= 0,
              visible.text.utf16.count <= Int.max - visible.offset, passage.text.utf16.count <= Int.max - passage.offset else { return }
        seen = max(visible.offset, passage.offset) < min(visible.offset + visible.text.utf16.count, passage.offset + passage.text.utf16.count)
    }
}
