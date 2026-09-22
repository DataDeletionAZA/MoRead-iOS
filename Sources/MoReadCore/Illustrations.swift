import Foundation

public struct BookIllustration: Codable, Identifiable, Hashable, Sendable {
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
        guard let source else { return true }
        return book.chapters.indices.contains(source.chapter) && book.chapters[source.chapter].revision == source.revision && ReadingScope(through: book.readThrough).allows(chapter: source.chapter, range: NSRange(location: source.offset, length: source.text.utf16.count))
    }
    public func validate() throws {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prompt.utf16.count <= ImageGenerationClient.maximumPromptLength,
              !model.isEmpty, model.utf8.count <= 1024, ["png", "jpg", "webp"].contains(fileExtension),
              (1...8192).contains(width), (1...8192).contains(height), width * height <= 32_000_000,
              (originalPrompt?.utf16.count ?? 0) <= ImageGenerationClient.maximumPromptLength, category.count <= 40, sourceThrough.chapter >= 0, sourceThrough.offset >= 0 else { throw MoReadError.invalid("插图记录无效。") }
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
    public func saveIllustration(data: Data, bookID: UUID, prompt: String, originalPrompt: String? = nil, model: String, source: SourcePassage? = nil, through: ReadingPosition) throws -> BookIllustration {
        let book = try book(bookID)
        guard !book.removed, book.hasBody, through <= book.readThrough else { throw MoReadError.invalid("书籍或已读范围发生变化，请重新生成。") }
        if let source {
            guard source.bookID == bookID, source.isValid(in: try chapter(source.chapter, in: book), scope: ReadingScope(through: through)) else { throw MoReadError.invalid("插图选段已经变化，请重新选择。") }
        }
        guard try illustrations(for: bookID).count < 10_000 else { throw MoReadError.invalid("这本书的插图已达到 10000 张。") }
        let info = try ImageGenerationClient.imageProperties(data)
        let item = BookIllustration(originalPrompt: originalPrompt, bookID: bookID, prompt: prompt, model: model, source: source, sourceThrough: through, fileExtension: info.extension, width: info.width, height: info.height)
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
