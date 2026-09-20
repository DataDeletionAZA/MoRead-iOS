import Foundation

public struct ChatToolTrace: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public let call: ChatToolCall
    public let title: String
    public var state = "running"
    public var preview = ""
    public init(call: ChatToolCall, title: String) { self.call = call; self.title = title }
}

public struct ReaderToolOutput: Sendable {
    public var text: String
    public var passages: [SourcePassage] = []
    public var books: [Book] = []
    public init(text: String, passages: [SourcePassage] = [], books: [Book] = []) { self.text = text; self.passages = passages; self.books = books }
}

public enum ReaderTools {
    public static let titles = ["find_books": "查找书籍", "get_reading_progress": "查看阅读进度", "list_chapters": "查看已读目录", "read_book_section": "读取已读章节", "grep_book": "查找原文关键词", "search_book": "按意思检索原文", "list_annotations": "查看批注", "list_notes": "查看笔记与梗概", "recall_memory": "回忆过往交流", "add_annotation": "添加原文批注", "write_note": "保存读书笔记", "save_plot_summary": "保存剧情梗概"]
    public static let writing = Set(["add_annotation", "write_note", "save_plot_summary"])
    public static func specs(currentBook: UUID?, memory: Bool, enabled: [String]? = nil) throws -> [ChatTool] {
        let string: [String: Any] = ["type": "string", "maxLength": 512], integer: [String: Any] = ["type": "integer", "minimum": 1]
        let definitions: [(String, String, [String: Any], [String])] = [
            ("find_books", "在本机书库按书名或作者查找书籍，返回后续工具使用的 book_id。", ["query": string], []),
            ("get_reading_progress", "查看书籍与当前阅读位置、已读边界和书签概况。", [:], []),
            ("list_chapters", "列出已读章节号与标题，章节号从 1 开始；先核对目录再读取章节。", ["from_chapter": integer, "to_chapter": integer], []),
            ("read_book_section", "读取已读原文，章节号从 1 开始。当前章截到已读位置，长章节按返回的偏移续读。", ["from_chapter": integer, "to_chapter": integer, "start_char": ["type": "integer", "minimum": 0], "max_chars": ["type": "integer", "minimum": 1000, "maximum": currentBook == nil ? 6000 : 24000]], ["from_chapter"]),
            ("grep_book", "在已读原文中查找明确的关键词或短语。", ["query": string], ["query"]),
            ("search_book", "根据问题检索已读原文，适合寻找相关情节与依据。", ["query": string], ["query"]),
            ("list_annotations", "查看已读范围内的划线、批注与角色段评。", [:], []),
            ("list_notes", "列出已读范围内的笔记和剧情梗概；按 note_id 分段读取全文，更新前先读旧稿。", ["kind": ["type": "string", "enum": ["all", "note", "plot_summary"]], "note_id": string, "start_char": ["type": "integer", "minimum": 0], "max_chars": ["type": "integer", "minimum": 1000, "maximum": currentBook == nil ? 6000 : 8000]], []),
            ("recall_memory", "回忆当前角色与用户过去交流中的偏好、事实与约定。", ["query": string], ["query"])
        ] + writingDefinitions
        return try definitions.compactMap { name, description, properties, required in
            guard (enabled == nil || enabled!.contains(name)), (name != "recall_memory" || memory), (name != "find_books" || currentBook == nil), (currentBook != nil || !writing.contains(name)) else { return nil }
            var properties = properties, required = required
            if !["find_books", "recall_memory"].contains(name) {
                properties["book_id"] = ["type": "string", "description": "find_books 返回的书籍 UUID；当前书籍伴读中可省略"]
                if currentBook == nil { required.append("book_id") }
            }
            let schema: [String: Any] = ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
            return ChatTool(name: name, description: description, parameters: try JSONSerialization.data(withJSONObject: schema))
        }
    }
    public static func book(arguments: [String: Any], currentBook: UUID?, books: [Book]) throws -> Book {
        let requested: UUID?
        if let value = arguments["book_id"] {
            guard let text = value as? String, let id = UUID(uuidString: text) else { throw MoReadError.invalid("book_id 必须是书库返回的书籍编号。") }
            requested = id
        } else { requested = currentBook }
        guard let id = requested, currentBook == nil || currentBook == id, let book = books.first(where: { $0.id == id && !$0.removed && $0.hasBody }) else { throw MoReadError.invalid("书籍不在本次可查阅范围，请先查找书籍编号。") }
        return book
    }
    public static func query(_ arguments: [String: Any], required: Bool = true) throws -> String {
        guard let text = arguments["query"] as? String ?? (required ? nil : ""), text.utf16.count <= 512, !required || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MoReadError.invalid("请提供不超过 512 个字符的检索词 query。") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public static func validate(_ book: Book, current: [Book]) throws {
        guard book.chapters.indices.contains(book.readThrough.chapter), book.readThrough.offset >= 0, book.readThrough.offset <= book.chapters[book.readThrough.chapter].length,
              let latest = current.first(where: { $0.id == book.id }), !latest.removed, latest.hasBody,
              latest.readThrough >= book.readThrough, latest.chapters.map(\.revision) == book.chapters.map(\.revision) else { throw MoReadError.invalid("书籍或已读范围已变化，请重新发送。") }
    }
    public static func execute(_ call: ChatToolCall, currentBook: UUID?, books: [Book], store: LibraryStore) throws -> ReaderToolOutput {
        try Task.checkCancellation()
        let args = try call.object()
        if call.name == "find_books" {
            let query = try query(args, required: false)
            let found = books.filter { !$0.removed && $0.hasBody && (currentBook == nil || $0.id == currentBook) && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.author.localizedCaseInsensitiveContains(query)) }.prefix(40)
            return ReaderToolOutput(text: found.map { "book_id=\($0.id)《\(String($0.title.prefix(200)))》作者：\(String($0.author.prefix(100)))；共 \($0.chapters.count) 章" }.joined(separator: "\n"))
        }
        let book = try book(arguments: args, currentBook: currentBook, books: books)
        try validate(book, current: [try store.book(book.id)])
        let scope = ReadingScope(through: book.readThrough)
        let last = min(book.chapters.count, book.readThrough.chapter + (book.readThrough.offset > 0 ? 1 : 0))
        var text = "", passages: [SourcePassage] = []
        switch call.name {
        case "get_reading_progress":
            let records = try store.records(for: book)
            let position = min(book.position, book.readThrough)
            text = "《\(book.title)》共 \(book.chapters.count) 章；当前位置第 \(position.chapter + 1) 章，章内偏移 \(position.offset)；已读边界第 \(book.readThrough.chapter + 1) 章，偏移 \(book.readThrough.offset)。书签 \(records.bookmarks.filter { $0.position <= book.readThrough }.count) 个。"
        case "list_chapters":
            let from = try integer(args, "from_chapter", fallback: 1, range: 1...max(1, last))
            let to = try integer(args, "to_chapter", fallback: min(last, from + 99), range: from...max(from, last))
            guard from <= last, to - from < 100 else { throw MoReadError.invalid("目录超出已读范围，或单次超过 100 章。") }
            text = book.chapters[(from - 1)..<to].map { "第 \($0.id + 1) 章：\(String($0.title.prefix(200)))" }.joined(separator: "\n")
        case "read_book_section":
            let from = try integer(args, "from_chapter", range: 1...max(1, last))
            let to = try integer(args, "to_chapter", fallback: from, range: from...max(from, last))
            guard from <= last, to - from < 5 else { throw MoReadError.invalid("读取范围超出已读章节，或单次超过 5 章。") }
            var budget = try integer(args, "max_chars", fallback: currentBook == nil ? 6000 : 12000, range: 1000...(currentBook == nil ? 6000 : 24000))
            let start = try integer(args, "start_char", fallback: 0, range: 0...Int.max)
            for chapterIndex in (from - 1)..<to {
                try Task.checkCancellation()
                let chapter = try store.chapter(chapterIndex, in: book), readable = scope.readableText(chapter)
                let offset = chapterIndex == from - 1 ? start : 0
                guard offset <= readable.utf16.count else { throw MoReadError.invalid("章内偏移超过已读原文。") }
                let lower = TextBoundary.floor(offset, in: readable), upper = TextBoundary.floor(lower + min(budget, readable.utf16.count - lower), in: readable)
                if upper > lower { passages.append(SourcePassage(bookID: book.id, chapter: chapter, offset: lower, text: (readable as NSString).substring(with: NSRange(location: lower, length: upper - lower)))); budget -= upper - lower }
                if upper < readable.utf16.count { text = "可继续读取第 \(chapterIndex + 1) 章，start_char=\(upper)。"; break }
                if budget == 0 { if chapterIndex + 1 < to { text = "可继续读取第 \(chapterIndex + 2) 章，start_char=0。" }; break }
            }
        case "grep_book":
            let query = try query(args)
            for info in book.chapters.prefix(last) where passages.count < 12 {
                try Task.checkCancellation()
                passages += BookSearch.find(query, in: try store.chapter(info.id, in: book), bookID: book.id, scope: scope, limit: 12 - passages.count)
            }
            if passages.isEmpty { text = "已读范围内没有找到该关键词。" }
        case "list_notes":
            text = try readNotes(arguments: args, book: book, records: store.records(for: book), maximum: currentBook == nil ? 6000 : 8000)
        case "list_annotations":
            let records = try store.records(for: book)
            var entries: [String] = [], remaining = 12000
            for annotation in records.annotations {
                try Task.checkCancellation()
                guard annotation.passage.chapter >= 0, annotation.passage.chapter < last,
                      annotation.sourceThrough.map({ $0 <= book.readThrough }) ?? true,
                      annotation.passage.isValid(in: try store.chapter(annotation.passage.chapter, in: book), scope: scope) else { continue }
                let line = "第 \(annotation.passage.chapter + 1) 章 · \(annotation.characterName ?? "用户")：\(TextBoundary.prefix(annotation.note, end: 1000))\n原文：\(TextBoundary.prefix(annotation.passage.text, end: 500))"
                guard line.utf16.count <= remaining else { break }
                entries.append(line); remaining -= line.utf16.count
                if entries.count == 30 { break }
            }
            text = entries.isEmpty ? "已读范围内没有对应记录。" : entries.joined(separator: "\n\n")
        default: throw MoReadError.invalid("没有这个可用工具。")
        }
        return ReaderToolOutput(text: TextBoundary.prefix(text, end: 24000), passages: passages, books: [book])
    }
    static func integer(_ args: [String: Any], _ key: String, fallback: Int? = nil, range: ClosedRange<Int>) throws -> Int {
        if args[key] == nil, let fallback { return fallback }
        let title = ["from_chapter": "起始章节", "to_chapter": "结束章节", "start_char": "章内位置", "max_chars": "读取长度"][key] ?? "查询参数"
        guard let number = args[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
              number.doubleValue >= Double(range.lowerBound), number.doubleValue < Double(Int.max),
              number.doubleValue <= Double(range.upperBound), number.doubleValue == Double(number.intValue) else { throw MoReadError.invalid("\(title)无效或超出本次可查阅范围。") }
        return number.intValue
    }
}
