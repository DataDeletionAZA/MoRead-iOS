import Foundation
import SwiftSoup

public struct EPUBAnchor: Codable, Equatable, Sendable {
    public let chapter: Int
    public let offset: Int
    public let locator: String
    public init(chapter: Int, offset: Int, locator: String) { self.chapter = chapter; self.offset = offset; self.locator = locator }
}

public struct EPUBSourceBlock: Encodable, Sendable {
    public let start: Int
    public let text: String
    public let selector: String
    public static func blocks(in chapter: Chapter, anchors: [EPUBAnchor]) throws -> [Self] {
        let anchors = anchors.filter { $0.chapter == chapter.id }.sorted { $0.offset < $1.offset }
        let source = chapter.text as NSString
        return try anchors.enumerated().compactMap { index, anchor in
            let end = (index + 1 < anchors.count ? anchors[index + 1].offset : source.length) - 1
            guard anchor.offset >= 0, end > anchor.offset, end < source.length,
                  let json = try JSONSerialization.jsonObject(with: Data(anchor.locator.utf8)) as? [String: Any],
                  let locations = json["locations"] as? [String: Any], let selector = locations["cssSelector"] as? String else { return nil }
            return .init(start: anchor.offset, text: source.substring(with: NSRange(location: anchor.offset, length: end - anchor.offset)), selector: selector)
        }
    }
}

public enum EPUBTextEditing {
    private static func whitespace(_ unit: UInt16) -> Bool {
        UnicodeScalar(unit).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
    }
    private static func compact(_ value: String) -> String { String(decoding: value.utf16.filter { !whitespace($0) }, as: UTF16.self) }
    private static func textNodes(_ root: Node) throws -> [TextNode] {
        var stack = [root], result: [TextNode] = [], count = 0
        while let node = stack.popLast() {
            try Task.checkCancellation(); count += 1
            guard count <= 1_000_000 else { throw MoReadError.invalid("本页的排版结构过大，无法编辑。") }
            if let element = node as? Element, ["script", "style"].contains(element.tagNameNormal()) { continue }
            if let text = node as? TextNode { result.append(text) }
            stack.append(contentsOf: node.getChildNodes().reversed())
        }
        return result
    }
    /// Edits text nodes only; illustrations, inline formatting and document metadata retain their elements.
    public static func replace(html: String, chapter: Chapter, anchors: [EPUBAnchor], range: NSRange, with replacement: String) throws -> String {
        guard html.utf8.count <= 16 * 1024 * 1024, replacement.utf16.count <= 20_000,
              range.location >= 0, range.length > 0, range.location <= chapter.text.utf16.count,
              range.length <= chapter.text.utf16.count - range.location,
              TextBoundary.floor(range.location, in: chapter.text) == range.location,
              TextBoundary.floor(NSMaxRange(range), in: chapter.text) == NSMaxRange(range) else { throw MoReadError.invalid("选中文字或本页大小无效，请重新选择。") }
        guard replacement.unicodeScalars.allSatisfy({ scalar in
            let value = scalar.value
            return [9, 10, 13].contains(value) || (0x20...0xD7FF).contains(value) || (0xE000...0xFFFD).contains(value) || (0x10000...0x10FFFF).contains(value)
        }) else { throw MoReadError.invalid("替换文字包含无法保存的隐藏字符，请移除后重试。") }
        let document = try SwiftSoup.parse(html)
        document.outputSettings().prettyPrint(pretty: false).syntax(syntax: .xml)
        typealias Point = (node: TextNode, offset: Int)
        typealias Segment = (node: TextNode, start: Int, length: Int)
        var start: Point?, end: Point?, cursors: [ObjectIdentifier: Int] = [:]
        var flattened: [ObjectIdentifier: (NSString, [Segment])] = [:]
        for block in try EPUBSourceBlock.blocks(in: chapter, anchors: anchors) {
            try Task.checkCancellation()
            if block.start >= NSMaxRange(range) { break }
            let elements = try document.select(block.selector)
            guard elements.size() == 1, let element = elements.first() else { throw MoReadError.invalid("无法准确对应书内排版，原文未修改。") }
            let identity = ObjectIdentifier(element)
            let source: NSString, segments: [Segment]
            if let cached = flattened[identity] { (source, segments) = cached }
            else {
                var flat = "", parts: [Segment] = [], count = 0
                for node in try textNodes(element) {
                    let text = compact(node.getWholeText()), length = text.utf16.count
                    parts.append((node, count, length)); count += length; flat += text
                }
                source = flat as NSString; segments = parts; flattened[identity] = (source, segments)
            }
            let cursor = min(cursors[identity] ?? 0, source.length)
            let match = source.range(of: compact(block.text), range: NSRange(location: cursor, length: source.length - cursor))
            guard match.location != NSNotFound else { throw MoReadError.invalid("正文索引与排版不一致，请重新打开书籍。") }
            cursors[identity] = NSMaxRange(match)
            func point(_ offset: Int) -> Point? {
                let units = Array(block.text.utf16), index = offset - block.start
                guard units.indices.contains(index), !whitespace(units[index]) else { return nil }
                let position = match.location + units.prefix(index).filter { !whitespace($0) }.count
                guard let segment = segments.first(where: { position >= $0.start && position < $0.start + $0.length }) else { return nil }
                var remaining = position - segment.start
                for (offset, unit) in segment.node.getWholeText().utf16.enumerated() where !whitespace(unit) {
                    if remaining == 0 { return (segment.node, offset) }; remaining -= 1
                }
                return nil
            }
            if range.location >= block.start, range.location < block.start + block.text.utf16.count { start = point(range.location) }
            if NSMaxRange(range) - 1 >= block.start, NSMaxRange(range) - 1 < block.start + block.text.utf16.count {
                if let last = point(NSMaxRange(range) - 1) { end = (last.node, last.offset + 1) }
            }
        }
        guard let start, let end else { throw MoReadError.invalid("无法准确定位所选文字的边界，请重新选择。") }
        let nodes = try textNodes(document)
        guard let first = nodes.firstIndex(where: { $0 === start.node }), let last = nodes.firstIndex(where: { $0 === end.node }), first <= last else { throw MoReadError.invalid("选中文字的顺序无效。") }
        let prefix = (start.node.getWholeText() as NSString).substring(to: start.offset)
        let suffix = (end.node.getWholeText() as NSString).substring(from: end.offset)
        for node in nodes[first...last] { node.text("") }
        // Newlines become explicit breaks so the renderer and Readium's text iterator agree.
        let lines = replacement.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        start.node.text(prefix + lines[0])
        var tail: Node = start.node
        for line in lines.dropFirst() {
            let br = Element(try Tag.valueOf("br"), ""), text = TextNode(line, "")
            _ = try tail.after(br); _ = try br.after(text); tail = text
        }
        if first == last {
            if let text = tail as? TextNode { text.text(text.getWholeText() + suffix) }
        } else { end.node.text(suffix) }
        try Task.checkCancellation()
        let result = try document.outerHtml()
        guard result.utf8.count <= 16 * 1024 * 1024 else { throw MoReadError.invalid("修改后的本页过大。") }
        return result
    }
}

extension LibraryStore {
    public func epubOverrides(_ bookID: UUID) throws -> [String: String] {
        let url = directory(bookID).appendingPathComponent("epub-overrides.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= 150 * 1024 * 1024 else { throw MoReadError.invalid("EPUB 修订文件过大。") }
        let values = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        try Self.validateEPUBOverrides(values); return values
    }
    static func validateEPUBOverrides(_ values: [String: String]) throws {
        guard values.count <= 50_000 else { throw MoReadError.invalid("EPUB 修订页数过多。") }
        var total = 0
        for (href, html) in values {
            total += html.utf8.count
            guard !href.isEmpty, href.utf8.count <= 4096, !href.contains("\0"),
                  let parts = URLComponents(string: href), parts.scheme == nil, parts.host == nil, parts.fragment == nil, parts.query == nil,
                  html.utf8.count <= 16 * 1024 * 1024, total <= 100 * 1024 * 1024 else { throw MoReadError.invalid("EPUB 修订内容无效。") }
        }
    }
    public func commitEPUBEdit(book: Book, passage: SourcePassage, chapters: [Chapter], anchors: [EPUBAnchor], overrides: [String: String], originalRecords: Data, originalOverrides: [String: String]) throws -> Book {
        try Task.checkCancellation()
        guard book.format == "epub", book.hasBody, !book.removed, chapters.count == book.chapters.count,
              chapters.enumerated().allSatisfy({ $0.offset == $0.element.id }), try self.book(book.id) == book,
              try epubOverrides(book.id) == originalOverrides else { throw MoReadError.invalid("书籍已变化，请重新选择原文。") }
        guard passage.bookID == book.id, passage.isValid(in: try chapter(passage.chapter, in: book), scope: .wholeBook) else { throw MoReadError.invalid("选中的原文已变化，请重新选择。") }
        try Self.validateEPUBOverrides(overrides)
        var changes: [Int: TextCleanupResult] = [:]
        for updated in chapters {
            let old = try chapter(updated.id, in: book)
            guard ChapterInfo(old) == book.chapters[updated.id] else { throw MoReadError.invalid("正文已变化，请重新选择。") }
            guard old.text != updated.text else { continue }
            guard updated.id == passage.chapter else { throw MoReadError.invalid("修订影响了其他章节，原书籍已保留。") }
            let a = old.text as NSString, b = updated.text as NSString
            var first = 0, suffix = 0
            while first < min(passage.offset, min(a.length, b.length)), a.character(at: first) == b.character(at: first) { first += 1 }
            first = min(TextBoundary.floor(first, in: old.text), TextBoundary.floor(first, in: updated.text))
            while suffix < min(a.length - passage.offset - passage.text.utf16.count, min(a.length, b.length) - first), a.character(at: a.length - suffix - 1) == b.character(at: b.length - suffix - 1) { suffix += 1 }
            while suffix > 0, TextBoundary.floor(a.length - suffix, in: old.text) != a.length - suffix || TextBoundary.floor(b.length - suffix, in: updated.text) != b.length - suffix { suffix -= 1 }
            changes[updated.id] = .init(text: updated.text, matches: 1, stages: [[.init(range: NSRange(location: first, length: a.length - first - suffix), length: b.length - first - suffix)]], sourceLength: a.length)
        }
        guard anchors.count <= 1_000_000, anchors.allSatisfy({ chapters.indices.contains($0.chapter) && $0.offset >= 0 && $0.offset < chapters[$0.chapter].text.utf16.count && $0.locator.utf8.count <= 100_000 }) else { throw MoReadError.invalid("修订后的 EPUB 定位信息无效。") }
        let files = ["epub-overrides.json": try JSONEncoder().encode(overrides), "epub-map.json": try JSONEncoder().encode(anchors)]
        return try applyTextEdits(book: book, chapters: chapters, changes: changes, originalRecords: originalRecords, extraFiles: files, epubAnchors: anchors)
    }
}
