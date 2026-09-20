import Foundation

public struct ReadingNote: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var title: String
    public var content: String
    public var kind = "note"
    public var characterID: UUID?
    public var characterName: String?
    public var conversationID: UUID?
    public var sourceThrough: ReadingPosition
    public var sourceRevisions: [String]
    public var fromChapter: Int?
    public var toChapter: Int?
    public var userEdited = false
    public var mutationKey: String?
    public var createdAt = Date()
    public var updatedAt = Date()
    public init(title: String, content: String, book: Book) {
        self.title = title; self.content = content; sourceThrough = book.readThrough; sourceRevisions = book.chapters.map(\.revision)
    }
    public var authorLabel: String { characterName.map { $0 + (userEdited ? " · 已由我编辑" : "") } ?? "我的笔记" }
    public func visible(in book: Book) -> Bool {
        sourceThrough >= ReadingPosition() && sourceThrough <= book.readThrough && sourceRevisions == book.chapters.map(\.revision)
    }
    public func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf16.count <= 120,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, content.utf16.count <= 50_000,
              ["note", "plot_summary"].contains(kind) else { throw MoReadError.invalid("请填写标题和正文；标题最多 120 字，正文最多 50000 字。") }
    }
}

extension ReaderTools {
    static var writingDefinitions: [(String, String, [String: Any], [String])] {
        let title: [String: Any] = ["type": "string", "maxLength": 120]
        let content: [String: Any] = ["type": "string", "maxLength": 50000]
        let id: [String: Any] = ["type": "string", "description": "list_notes 返回的笔记 UUID"]
        let chapter: [String: Any] = ["type": "integer", "minimum": 1]
        return [
            ("add_annotation", "对已读原文添加角色批注。用户要求或确有值得补充的观点时使用；quote 必须从原文逐字复制。重复引文请提供查询结果中的 source_ref。", ["quote": ["type": "string", "maxLength": 2000], "comment": ["type": "string", "maxLength": 10000], "style": ["type": "string", "enum": ["highlight", "underline", "wavy"]], "source_ref": ["type": "string"], "chapter_number": chapter], ["quote", "comment"]),
            ("write_note", "仅在用户要求保存时，把完整 Markdown 笔记写入当前书籍。省略 note_id 新建，提供时更新自己的笔记；更新前先 list_notes 读旧稿。不能改写手写、用户已编辑或其他角色的笔记。", ["title": title, "content_md": content, "note_id": id], ["title", "content_md"]),
            ("save_plot_summary", "保存截至已读进度的完整 Markdown 剧情梗概。默认更新当前角色最新梗概，更新前先 list_notes 读旧稿；as_new=true 新建。不能包含未读剧情或改写用户、其他角色的内容。", ["title": title, "content_md": content, "note_id": id, "as_new": ["type": "boolean"], "from_chapter": chapter, "to_chapter": chapter], ["content_md"])
        ]
    }

    public static func readNotes(arguments args: [String: Any], book: Book, records: BookRecords, maximum: Int = 8000) throws -> String {
        let notes = (records.notes ?? []).filter { $0.visible(in: book) }.sorted { $0.updatedAt > $1.updatedAt }
        if let raw = args["note_id"] {
            guard let string = raw as? String, let id = UUID(uuidString: string), let note = notes.first(where: { $0.id == id }) else { throw MoReadError.invalid("找不到可在当前已读范围查看的笔记。") }
            let start = try integer(args, "start_char", fallback: 0, range: 0...note.content.utf16.count)
            let size = try integer(args, "max_chars", fallback: 6000, range: 1000...maximum)
            let lower = TextBoundary.floor(start, in: note.content), upper = TextBoundary.floor(lower + min(size, note.content.utf16.count - lower), in: note.content)
            let text = (note.content as NSString).substring(with: NSRange(location: lower, length: upper - lower))
            return "note_id=\(note.id) · \(note.title) · \(note.authorLabel)\n" + text + (upper < note.content.utf16.count ? "\n内容未完，继续读取 start_char=\(upper)。" : "")
        }
        guard let kind = args["kind"] as? String ?? (args["kind"] == nil ? "all" : nil), ["all", "note", "plot_summary"].contains(kind) else { throw MoReadError.invalid("请选择笔记、梗概或全部内容。") }
        var lines: [String] = [], size = 0
        for note in notes where kind == "all" || kind == note.kind {
            let label = note.kind == "plot_summary" ? "梗概" : "笔记"
            let line = "note_id=\(note.id) [\(label)] \(note.title) · 作者：\(note.authorLabel) · \(note.content.utf16.count) 字\n" + TextBoundary.prefix(note.content, end: 100)
            if lines.count == 50 || size + line.utf16.count > 12000 { lines.append("目录已截断，可按内容类型筛选。"); break }
            lines.append(line); size += line.utf16.count
        }
        return lines.isEmpty ? "已读范围内还没有独立笔记或剧情梗概。" : lines.joined(separator: "\n\n")
    }

    public static func writingNote(_ call: ChatToolCall, book: Book, records: BookRecords, character: CharacterCard, conversationID: UUID, mutationKey: String) throws -> ReadingNote {
        guard ["write_note", "save_plot_summary"].contains(call.name) else { throw MoReadError.invalid("笔记工具无效。") }
        try validate(book, current: [book])
        let args = try call.object(), kind = call.name == "save_plot_summary" ? "plot_summary" : "note"
        let notes = records.notes ?? []
        if let prior = notes.first(where: { $0.mutationKey == mutationKey }) { return prior }
        let requested: ReadingNote?
        if let raw = args["note_id"] {
            guard let string = raw as? String, let id = UUID(uuidString: string), let value = notes.first(where: { $0.id == id }) else { throw MoReadError.invalid("找不到要更新的笔记，请先查看笔记目录。") }
            requested = value
        } else { requested = nil }
        var asNew = false
        if let value = args["as_new"] {
            guard let boolean = value as? NSNumber, CFGetTypeID(boolean) == CFBooleanGetTypeID() else { throw MoReadError.invalid("新建选项必须为 true 或 false。") }
            asNew = boolean.boolValue
        }
        let latest = kind == "plot_summary" ? notes.filter { $0.characterID == character.id && $0.kind == kind }.max { $0.updatedAt < $1.updatedAt } : nil
        let target = asNew ? nil : requested ?? latest
        if let target {
            guard target.characterID == character.id, !target.userEdited, target.kind == kind else { throw MoReadError.invalid("只能更新当前角色创建且未被用户编辑的同类笔记，请新建一条。") }
            guard target.visible(in: book) else { throw MoReadError.invalid("旧笔记超出当前已读范围或原文版本已变化，请新建一条。") }
        }
        let content = try field(args, "content_md", limit: 50000, label: "笔记正文")
        var note = target ?? ReadingNote(title: "伴读笔记", content: content, book: book)
        note.content = content; note.characterID = character.id; note.characterName = character.name; note.conversationID = conversationID
        note.sourceThrough = book.readThrough; note.sourceRevisions = book.chapters.map(\.revision); note.updatedAt = Date(); note.mutationKey = mutationKey
        var fallback = "伴读笔记"
        if kind == "plot_summary" {
            let last = book.readThrough.chapter + (book.readThrough.offset > 0 ? 1 : 0)
            guard last > 0 else { throw MoReadError.invalid("还没有可保存梗概的已读章节。") }
            let from = try integer(args, "from_chapter", fallback: 1, range: 1...last)
            let to = try integer(args, "to_chapter", fallback: last, range: from...last)
            note.fromChapter = from; note.toChapter = to; fallback = "剧情梗概 · 第 \(from)–\(to) 章"
        }
        note.kind = kind; note.title = try field(args, "title", limit: 120, label: "笔记标题", fallback: fallback)
        try note.validate(); return note
    }

    public static func writingAnnotation(_ call: ChatToolCall, book: Book, sources: [SourcePassage], character: CharacterCard, store: LibraryStore, mutationKey: String) throws -> Annotation {
        let args = try call.object(), comment = try field(args, "comment", limit: 10000, label: "批注内容")
        guard let quote = args["quote"] as? String, !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, quote.utf16.count <= 2000 else { throw MoReadError.invalid("请逐字引用不超过 2000 字的连续原文。") }
        let style = try field(args, "style", limit: 20, label: "批注样式", fallback: "highlight")
        guard ["highlight", "underline", "wavy"].contains(style) else { throw MoReadError.invalid("请选择荧光、下划线或波浪线批注。") }
        try validate(book, current: [try store.book(book.id)])
        let last = book.readThrough.chapter + (book.readThrough.offset > 0 ? 1 : 0)
        guard last > 0 else { throw MoReadError.invalid("还没有可添加批注的已读原文。") }
        let requested = args["chapter_number"] == nil ? nil : try integer(args, "chapter_number", range: 1...last)
        let scope = ReadingScope(through: book.readThrough)
        var match: SourcePassage?
        func locate(_ text: String, chapter: Chapter, offset: Int) throws {
            let body = text as NSString
            var start = 0
            while start < body.length {
                let found = body.range(of: quote, options: .literal, range: NSRange(location: start, length: body.length - start))
                if found.location == NSNotFound { break }
                guard match == nil else { throw MoReadError.invalid("引文在范围内出现多次，请提供来源编号或更完整的唯一引文。") }
                match = SourcePassage(bookID: book.id, chapter: chapter, offset: offset + found.location, text: quote)
                start = found.location + 1
            }
        }
        if let raw = args["source_ref"] {
            guard let reference = raw as? String, let source = sources.first(where: { $0.id == reference && $0.bookID == book.id }), requested == nil || requested == source.chapter + 1 else { throw MoReadError.invalid("来源编号无效，请重新查询原文后再添加批注。") }
            let chapter = try store.chapter(source.chapter, in: book)
            guard source.isValid(in: chapter, scope: scope) else { throw MoReadError.invalid("来源已失效，请重新查询原文。") }
            try locate(source.text, chapter: chapter, offset: source.offset)
        } else {
            let range = requested.map { ($0 - 1)..<$0 } ?? 0..<last
            guard range.count <= 20000 else { throw MoReadError.invalid("核验范围过大，请提供查询结果中的来源编号。") }
            var scanned = 0
            for index in range {
                try Task.checkCancellation()
                let chapter = try store.chapter(index, in: book), text = scope.readableText(chapter)
                scanned += text.utf16.count
                guard scanned <= 20_000_000 else { throw MoReadError.invalid("核验范围过大，请提供查询结果中的来源编号。") }
                try locate(text, chapter: chapter, offset: 0)
            }
        }
        guard let passage = match, passage.isValid(in: try store.chapter(passage.chapter, in: book), scope: scope) else { throw MoReadError.invalid("已读原文中找不到这段引文，请逐字复制查询结果。") }
        try Task.checkCancellation(); try validate(book, current: [try store.book(book.id)])
        var annotation = Annotation(passage: passage, note: comment, style: style == "wavy" ? "wave" : style)
        annotation.characterID = character.id; annotation.characterName = character.name; annotation.sourceThrough = book.readThrough; annotation.generationKey = mutationKey
        return annotation
    }
    private static func field(_ args: [String: Any], _ key: String, limit: Int, label: String, fallback: String? = nil) throws -> String {
        guard let raw = args[key] as? String ?? (args[key] == nil ? fallback : nil) else { throw MoReadError.invalid("请提供\(label)。") }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty, let fallback { return fallback }
        guard !text.isEmpty, text.utf16.count <= limit else { throw MoReadError.invalid("\(label)不能为空且不得超过 \(limit) 字。") }
        return text
    }
}
