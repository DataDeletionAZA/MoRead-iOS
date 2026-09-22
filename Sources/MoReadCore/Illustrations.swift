import Foundation

public struct BookIllustration: Codable, Identifiable, Hashable, Sendable {
    public var anchor: ReadingPosition?
    public var anchorRevision: String?
    public var characterID: UUID?
    public var characterName: String?
    public var originalPrompt: String?
    public var id = UUID()
    public let bookID: UUID
    public let prompt: String
    public let model: String
    public let source: SourcePassage?
    public let sourceThrough: ReadingPosition
    public let fileExtension: String
    public let width: Int
    public let height: Int
    public var category = ""
    public var createdAt = Date()
    public func visible(in book: Book) -> Bool {
        guard book.id == bookID, sourceThrough <= book.readThrough else { return false }
        if let anchor, let anchorRevision {
            guard book.chapters.indices.contains(anchor.chapter), book.chapters[anchor.chapter].revision == anchorRevision else { return false }
        }
        guard let source else { return true }
        return book.chapters.indices.contains(source.chapter) && book.chapters[source.chapter].revision == source.revision && ReadingScope(through: book.readThrough).allows(chapter: source.chapter, range: NSRange(location: source.offset, length: source.text.utf16.count))
    }
    public func validate() throws {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prompt.utf16.count <= ImageGenerationClient.maximumPromptLength,
              !model.isEmpty, model.utf8.count <= 1024, ["png", "jpg", "webp"].contains(fileExtension),
              (1...8192).contains(width), (1...8192).contains(height), width * height <= 32_000_000,
              (originalPrompt?.utf16.count ?? 0) <= ImageGenerationClient.maximumPromptLength, category.count <= 40, sourceThrough.chapter >= 0, sourceThrough.offset >= 0 else { throw MoReadError.invalid("插图记录无效。") }
        if let anchor { guard anchor.chapter >= 0, anchor.offset >= 0, anchor <= sourceThrough else { throw MoReadError.invalid("插图位置超出已读范围。") } }
        if let anchorRevision { guard anchor != nil, anchorRevision.count == 64, anchorRevision.allSatisfy({ $0.isHexDigit }) else { throw MoReadError.invalid("插图原文版本无效。") } }
        guard (characterName?.utf16.count ?? 0) <= 512 else { throw MoReadError.invalid("插图作者名称过长。") }
        if let source {
            guard source.bookID == bookID, source.text.utf16.count <= 24_000, !source.text.isEmpty,
                  ReadingScope(through: sourceThrough).allows(chapter: source.chapter, range: NSRange(location: source.offset, length: source.text.utf16.count)) else { throw MoReadError.invalid("插图原文位置无效。") }
        }
    }
}

extension LibraryStore {
    private func illustrationsDirectory(_ bookID: UUID) -> URL { directory(bookID).appendingPathComponent("illustrations", isDirectory: true) }
    public func illustrations(for bookID: UUID) throws -> [BookIllustration] {
        _ = try book(bookID)
        let root = illustrationsDirectory(bookID)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let directories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { UUID(uuidString: $0.lastPathComponent) != nil }
        guard directories.count <= 10_000 else { throw MoReadError.invalid("这本书的插图超过 10000 张。") }
        return try directories.map { directory in
            let raw = try CharacterCardImporter.read(directory.appendingPathComponent("record.json"), limit: 256 * 1024)
            let item = try JSONDecoder().decode(BookIllustration.self, from: raw); try item.validate()
            guard item.id == UUID(uuidString: directory.lastPathComponent), item.bookID == bookID else { throw MoReadError.invalid("插图编号与书籍不一致。") }
            return item
        }.sorted { $0.createdAt > $1.createdAt }
    }
    public func illustrationURL(_ item: BookIllustration) throws -> URL {
        try item.validate(); _ = try book(item.bookID)
        return illustrationsDirectory(item.bookID).appendingPathComponent(item.id.uuidString).appendingPathComponent("image." + item.fileExtension)
    }
    public func illustrationData(_ item: BookIllustration) throws -> Data {
        let data = try CharacterCardImporter.read(illustrationURL(item), limit: ImageGenerationClient.maximumBytes)
        let info = try ImageGenerationClient.imageProperties(data)
        guard info.extension == item.fileExtension, info.width == item.width, info.height == item.height else { throw MoReadError.invalid("插图文件与记录不一致。") }
        return data
    }
    public func saveIllustration(data: Data, bookID: UUID, prompt: String, originalPrompt: String? = nil, model: String, source: SourcePassage? = nil, through: ReadingPosition, anchor: ReadingPosition? = nil, characterID: UUID? = nil, characterName: String? = nil) throws -> BookIllustration {
        let book = try book(bookID)
        guard !book.removed, book.hasBody, through <= book.readThrough else { throw MoReadError.invalid("书籍或已读范围发生变化，请重新生成。") }
        if let source {
            guard source.bookID == bookID, source.isValid(in: try chapter(source.chapter, in: book), scope: ReadingScope(through: through)) else { throw MoReadError.invalid("插图选段已经变化，请重新选择。") }
        }
        guard try illustrations(for: bookID).count < 10_000 else { throw MoReadError.invalid("这本书的插图已达到 10000 张。") }
        let info = try ImageGenerationClient.imageProperties(data)
        let anchor = source.map { ReadingPosition(chapter: $0.chapter, offset: $0.offset) } ?? anchor
        if let anchor {
            guard book.chapters.indices.contains(anchor.chapter), anchor.offset >= 0, anchor.offset <= book.chapters[anchor.chapter].length,
                  TextBoundary.floor(anchor.offset, in: try chapter(anchor.chapter, in: book).text) == anchor.offset else { throw MoReadError.invalid("插图位置无效。") }
        }
        let item = BookIllustration(anchor: anchor, anchorRevision: anchor.map { book.chapters[$0.chapter].revision }, characterID: characterID, characterName: characterName, originalPrompt: originalPrompt, bookID: bookID, prompt: prompt, model: model, source: source, sourceThrough: through, fileExtension: info.extension, width: info.width, height: info.height)
        try item.validate()
        let root = illustrationsDirectory(bookID), manager = FileManager.default
        let staging = root.appendingPathComponent(".pending-" + item.id.uuidString, isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }
        try data.write(to: staging.appendingPathComponent("image." + item.fileExtension), options: .atomic)
        try JSONEncoder().encode(item).write(to: staging.appendingPathComponent("record.json"), options: .atomic)
        try manager.moveItem(at: staging, to: root.appendingPathComponent(item.id.uuidString))
        return item
    }
    public func locateIllustration(_ item: BookIllustration) throws -> SourcePassage {
        let book = try book(item.bookID)
        guard !book.removed, book.hasBody,
              let saved = try illustrations(for: book.id).first(where: { $0.id == item.id }), saved.visible(in: book) else { throw MoReadError.invalid("插图或原文当前不可用。") }
        let scope = ReadingScope(through: min(saved.sourceThrough, book.readThrough))
        if let source = saved.source {
            guard source.isValid(in: try chapter(source.chapter, in: book), scope: scope) else { throw MoReadError.invalid("插图原文已经变化。") }
            return source
        }
        guard let anchor = saved.anchor, let revision = saved.anchorRevision else { throw MoReadError.invalid("这张插图没有可定位的原文。") }
        let chapter = try chapter(anchor.chapter, in: book), text = scope.readableText(chapter)
        guard chapter.revision == revision, !text.isEmpty, anchor.offset <= text.utf16.count,
              TextBoundary.floor(anchor.offset, in: text) == anchor.offset else { throw MoReadError.invalid("插图原文或已读范围已经变化。") }
        let start = TextBoundary.floor(min(anchor.offset, text.utf16.count - 1), in: text)
        let end = TextBoundary.floor(min(text.utf16.count, start + 180), in: text)
        return SourcePassage(bookID: book.id, chapter: chapter, offset: start, text: (text as NSString).substring(with: NSRange(location: start, length: end - start)))
    }
    public func categorizeIllustration(_ item: BookIllustration, category: String) throws {
        guard var saved = try illustrations(for: item.bookID).first(where: { $0.id == item.id }) else { throw MoReadError.invalid("插图已被移除。") }
        saved.category = category.trimmingCharacters(in: .whitespacesAndNewlines); try saved.validate()
        try JSONEncoder().encode(saved).write(to: illustrationsDirectory(item.bookID).appendingPathComponent(item.id.uuidString).appendingPathComponent("record.json"), options: .atomic)
    }
    public func deleteIllustration(_ item: BookIllustration) throws {
        guard try illustrations(for: item.bookID).contains(where: { $0.id == item.id }) else { throw MoReadError.invalid("插图已被移除。") }
        try FileManager.default.removeItem(at: illustrationsDirectory(item.bookID).appendingPathComponent(item.id.uuidString))
    }
}

public struct IllustrationReference: Codable, Hashable, Sendable {
    public let bookID: UUID
    public let illustrationID: UUID
    public init(_ image: BookIllustration) { bookID = image.bookID; illustrationID = image.id }
}

public struct IllustrationToolRequest: Sendable {
    public let prompt: String
    public let source: SourcePassage?
    public let anchor: ReadingPosition
    public init(call: ChatToolCall, book: Book, sources: [SourcePassage], store: LibraryStore) throws {
        let args = try call.object()
        guard call.name == "generate_illustration", let prompt = args["prompt"] as? String,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prompt.utf16.count <= ImageGenerationClient.maximumPromptLength else { throw MoReadError.invalid("请提供不超过 24000 字的画面描述。") }
        try ReaderTools.validate(book, current: [try store.book(book.id)])
        let chapterIndex = try ReaderTools.integer(args, "chapter_number", fallback: book.readThrough.chapter + 1, range: 1...(book.readThrough.chapter + 1)) - 1
        let chapter = try store.chapter(chapterIndex, in: book), scope = ReadingScope(through: book.readThrough)
        let readable = scope.readableText(chapter)
        let offset = try ReaderTools.integer(args, "char_offset", fallback: chapterIndex == book.readThrough.chapter ? book.readThrough.offset : 0, range: 0...readable.utf16.count)
        guard TextBoundary.floor(offset, in: readable) == offset else { throw MoReadError.invalid("插图位置应落在完整文字边界。") }
        var passage: SourcePassage?
        if let raw = args["source_text"] {
            guard let quote = raw as? String, !quote.isEmpty, quote.utf16.count <= 2000 else { throw MoReadError.invalid("插图原文需为 1 至 2000 字。") }
            let text: String, start: Int
            if let raw = args["source_ref"] {
                guard let id = raw as? String, let source = sources.first(where: { $0.id == id && $0.bookID == book.id && $0.chapter == chapterIndex }), source.isValid(in: chapter, scope: scope) else { throw MoReadError.invalid("插图来源编号无效，请重新查阅原文。") }
                text = source.text; start = source.offset
            } else { text = readable; start = 0 }
            let body = text as NSString
            var range = body.range(of: quote, options: .literal)
            if args["char_offset"] != nil {
                let local = offset - start
                guard local >= 0, local <= body.length, quote.utf16.count <= body.length - local else { throw MoReadError.invalid("插图引文与位置不符。") }
                range = NSRange(location: local, length: quote.utf16.count)
                guard body.substring(with: range) == quote else { throw MoReadError.invalid("插图引文与位置不符。") }
            } else if range.location != NSNotFound {
                let next = range.location + 1
                guard body.range(of: quote, options: .literal, range: NSRange(location: next, length: body.length - next)).location == NSNotFound else { throw MoReadError.invalid("插图引文出现多次，请提供准确位置或来源编号。") }
            }
            guard range.location != NSNotFound else { throw MoReadError.invalid("已读原文中找不到这段插图引文。") }
            let value = SourcePassage(bookID: book.id, chapter: chapter, offset: start + range.location, text: quote)
            guard value.isValid(in: chapter, scope: scope) else { throw MoReadError.invalid("插图引文超出已读范围。") }
            passage = value
        } else if args["source_ref"] != nil { throw MoReadError.invalid("请同时提供要引用的原文。") }
        self.prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines); source = passage
        anchor = .init(chapter: chapterIndex, offset: passage?.offset ?? offset)
    }
}
