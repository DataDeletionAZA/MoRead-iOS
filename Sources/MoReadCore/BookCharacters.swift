import Foundation

public struct CharacterEvidence: Codable, Hashable, Sendable {
    public let chapter: Int
    public let fact: KnowledgeFact
}
public struct BookCharacter: Codable, Equatable, Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let evidence: [CharacterEvidence]
}
public struct BookCharacterGuide: Codable, Equatable, Sendable {
    public let bookID: UUID
    public let generationID: UUID
    public let sourceRevision: String
    public let modelFingerprint: String
    public let modelLabel: String
    public let promptVersion: Int
    public let sourceThrough: ReadingPosition?
    public let scannedChapters: Int
    public let sourceCharacters: Int64
    public let characters: [BookCharacter]
    public let createdAt: Date
    public var progressBounded: Bool { sourceThrough != nil }
    public func visible(in book: Book) -> Bool {
        book.id == bookID && !book.removed && book.hasBody && sourceRevision == MemoryBookScope.fingerprint(book.chapters.map(\.revision)) &&
        (sourceThrough.map { $0 <= book.readThrough } ?? true) && (try? validate()) != nil
    }
    func validate() throws {
        guard promptVersion == 1, ChapterKnowledgeEntry.validHash(sourceRevision), ChapterKnowledgeEntry.validHash(modelFingerprint),
              !modelLabel.isEmpty, modelLabel.utf16.count <= 500, scannedChapters > 0, sourceCharacters > 0,
              sourceThrough.map({ $0.chapter >= 0 && $0.offset >= 0 }) ?? true,
              Set(characters.map(\.name)).count == characters.count, createdAt.timeIntervalSince1970.isFinite else {
            throw MoReadError.invalid("人物资料的来源记录无效。")
        }
        for person in characters {
            guard ChapterKnowledge.validName(person.name), (1...16).contains(person.evidence.count) else { throw MoReadError.invalid("人物资料的名称或依据数量无效。") }
            for evidence in person.evidence {
                try evidence.fact.validate(sourceEnd: Int.max)
                guard evidence.chapter >= 0, sourceThrough.map({ ReadingScope(through: $0).allows(chapter: evidence.chapter, range: NSRange(location: evidence.fact.start, length: evidence.fact.end - evidence.fact.start)) }) ?? true else {
                    throw MoReadError.invalid("人物依据超出资料的阅读范围。")
                }
            }
        }
    }
}

struct BookCharacterAccumulator {
    private var names: [String] = []
    private var people: [String: [CharacterEvidence]] = [:]
    mutating func add(chapter: Int, characters: [KnowledgeCharacter]) {
        for person in characters {
            if people[person.name] == nil { names.append(person.name) }
            var texts: Set<String> = []
            let values = ((people[person.name] ?? []) + person.facts.map { CharacterEvidence(chapter: chapter, fact: $0) })
                .filter { texts.insert($0.fact.text).inserted }
                .sorted { $0.chapter == $1.chapter ? $0.fact.start < $1.fact.start : $0.chapter < $1.chapter }
            people[person.name] = values.count <= 16 ? values : Array(values.prefix(4)) + values.suffix(12)
        }
    }
    var characters: [BookCharacter] { names.map { .init(name: $0, evidence: people[$0] ?? []) } }
}

public struct BookCharactersCheckpoint: Codable, Sendable {
    public let bookID: UUID
    public let generationID: UUID
    public let sourceRevision: String
    public let modelFingerprint: String
    public let sourceThrough: ReadingPosition?
    public let promptVersion: Int
    public var completedParts: Int
    func validate() throws {
        guard promptVersion == 1, completedParts >= 0, ChapterKnowledgeEntry.validHash(sourceRevision), ChapterKnowledgeEntry.validHash(modelFingerprint),
              sourceThrough.map({ $0.chapter >= 0 && $0.offset >= 0 }) ?? true else { throw MoReadError.invalid("人物提取进度无效。") }
    }
}
public struct BookCharactersPlan: Sendable {
    public let bookID: UUID
    public let bookTitle: String
    public let chapters: [ChapterInfo]
    public let sourceRevision: String
    public let sourceThrough: ReadingPosition?
    public let modelFingerprint: String
    public let modelLabel: String
    public let generationID: UUID
    public let completedParts: Int
    public let sourceCharacters: Int64
    public let maximumRequests: Int64
    public let resuming: Bool
    let previousGeneration: UUID?
    let previousCheckpoint: UUID?
    public var progressBounded: Bool { sourceThrough != nil }
}
private struct CharacterPartCache: Codable {
    let bookID: UUID
    let chapter: Int
    let start: Int
    let end: Int
    let sourceRevision: String
    let sourceHash: String
    let modelFingerprint: String
    let promptVersion: Int
    let characters: [KnowledgeCharacter]
    var fileName: String { "part-\(chapter)-\(start).json" }
    func validate() throws {
        guard chapter >= 0, start >= 0, end > start, end - start <= 10_000, promptVersion == 1,
              ChapterKnowledgeEntry.validHash(sourceRevision), ChapterKnowledgeEntry.validHash(sourceHash), ChapterKnowledgeEntry.validHash(modelFingerprint), characters.count <= 24 else {
            throw MoReadError.invalid("人物分段缓存的来源记录无效。")
        }
        for person in characters {
            guard ChapterKnowledge.validName(person.name), (1...4).contains(person.facts.count) else { throw MoReadError.invalid("人物缓存内容无效。") }
            for fact in person.facts { try fact.validate(sourceEnd: end); guard fact.start >= start else { throw MoReadError.invalid("人物依据超出分段范围。") } }
        }
    }
}

public final class BookCharactersStore {
    private let library: LibraryStore
    public let bookID: UUID
    public var directory: URL { library.directory(bookID).appendingPathComponent("characters", isDirectory: true) }
    @MainActor private static var active: Set<URL> = []
    public init(library: LibraryStore, bookID: UUID) { self.library = library; self.bookID = bookID }
    public func guide() throws -> BookCharacterGuide? {
        let value: BookCharacterGuide? = try read("guide.json", limit: 128 * 1024 * 1024)
        if let value { try value.validate(); guard value.bookID == bookID else { throw MoReadError.invalid("人物资料与书籍不一致。") } }
        return value
    }
    public func checkpoint() throws -> BookCharactersCheckpoint? {
        let value: BookCharactersCheckpoint? = try read("checkpoint.json", limit: 16 * 1024)
        if let value { try value.validate(); guard value.bookID == bookID else { throw MoReadError.invalid("人物进度与书籍不一致。") } }
        return value
    }
    public func preview(modelFingerprint: String, modelLabel: String, progressBounded: Bool = true) throws -> BookCharactersPlan {
        let book = try library.book(bookID)
        guard !book.removed, book.hasBody, ChapterKnowledgeEntry.validHash(modelFingerprint), !modelLabel.isEmpty, modelLabel.utf16.count <= 500 else {
            throw MoReadError.invalid("书籍正文或整理模型不可用。")
        }
        let through = progressBounded ? book.readThrough : nil
        let chapters = book.chapters.filter { chapter in chapter.length > 0 && (through.map { end in chapter.id < end.chapter || (chapter.id == end.chapter && end.offset > 0) } ?? true) }
        guard !chapters.isEmpty else { throw MoReadError.invalid(progressBounded ? "还没有已读正文可以提取。" : "这本书没有可提取的正文。") }
        var count: Int64 = 0, requests: Int64 = 0
        for chapter in chapters {
            let length = Int64(through.map { $0.chapter == chapter.id ? min($0.offset, chapter.length) : chapter.length } ?? chapter.length)
            let (total, overflow) = count.addingReportingOverflow(length)
            guard length > 0, !overflow else { throw MoReadError.invalid("书籍字数无效。") }
            count = total
            let maximum = (length / 5000 + (length % 5000 > 0 ? 1 : 0)) * 2
            let (next, tooMany) = requests.addingReportingOverflow(maximum)
            guard !tooMany else { throw MoReadError.invalid("人物提取范围过大。") }; requests = next
        }
        let revision = MemoryBookScope.fingerprint(book.chapters.map(\.revision)), saved = try guide(), checkpoint = try checkpoint()
        let resume = checkpoint.flatMap { value in
            value.generationID != saved?.generationID && value.sourceRevision == revision && value.modelFingerprint == modelFingerprint && value.sourceThrough == through ? value : nil
        }
        return .init(bookID: book.id, bookTitle: book.title, chapters: chapters, sourceRevision: revision, sourceThrough: through,
                     modelFingerprint: modelFingerprint, modelLabel: modelLabel, generationID: resume?.generationID ?? UUID(), completedParts: resume?.completedParts ?? 0,
                     sourceCharacters: count, maximumRequests: requests, resuming: resume != nil, previousGeneration: saved?.generationID, previousCheckpoint: checkpoint?.generationID)
    }
    @discardableResult public func validatePlan(_ plan: BookCharactersPlan, active: Bool = false) throws -> Book {
        try Task.checkCancellation()
        let book = try library.book(bookID)
        guard plan.bookID == bookID, !book.removed, book.hasBody,
              plan.sourceRevision == MemoryBookScope.fingerprint(book.chapters.map(\.revision)),
              plan.sourceThrough.map({ $0 <= book.readThrough }) ?? true else { throw MoReadError.invalid("正文或已读范围已变化，请重新提取人物。") }
        if active, try checkpoint()?.generationID != plan.generationID { throw MoReadError.invalid("人物提取进度已变化，请重新确认。") }
        return book
    }
    @MainActor public func generate(_ plan: BookCharactersPlan, stream: @escaping ChapterKnowledgeAgent.Stream,
                                    validate: @escaping @Sendable () async throws -> Void,
                                    progress: @Sendable (Int, Int, String) async -> Void = { _, _, _ in }) async throws -> BookCharacterGuide {
        guard Self.active.insert(directory).inserted else { throw MoReadError.invalid("这本书正在提取人物。") }
        defer { Self.active.remove(directory) }
        try await validate(); try validatePlan(plan)
        guard try guide()?.generationID == plan.previousGeneration, try checkpoint()?.generationID == plan.previousCheckpoint else {
            throw MoReadError.invalid("人物资料已变化，请重新确认。")
        }
        var checkpoint = BookCharactersCheckpoint(bookID: bookID, generationID: plan.generationID, sourceRevision: plan.sourceRevision,
                                                 modelFingerprint: plan.modelFingerprint, sourceThrough: plan.sourceThrough, promptVersion: 1, completedParts: 0)
        try write(checkpoint, name: "checkpoint.json", limit: 16 * 1024)
        var accumulator = BookCharacterAccumulator()
        for (index, chapter) in plan.chapters.enumerated() {
            try await validate()
            let book = try validatePlan(plan, active: true), original = try library.chapter(chapter.id, in: book)
            let source = (plan.sourceThrough.map(ReadingScope.init(through:)) ?? .wholeBook).readableText(original)
            if !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                for part in try KnowledgePart.split(source, enforceChapterLimit: false) where !part.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try await validate(); try validatePlan(plan, active: true)
                    await progress(index, plan.chapters.count, "\(chapter.title) · 已核对 \(checkpoint.completedParts) 段")
                    let hash = ChapterKnowledgeEntry.hash(part.text)
                    let cached = try? cachedCharacters(chapter: chapter.id, part: part, plan: plan, hash: hash)
                    let people: [KnowledgeCharacter]
                    if let cached { people = cached }
                    else {
                        people = try await ChapterKnowledgeAgent.characters(bookTitle: plan.bookTitle, chapterTitle: chapter.title, part: part, stream: stream) {
                            try await validate()
                            _ = try await self.validateDuringGeneration(plan)
                        }
                    }
                    try await validate(); try validatePlan(plan, active: true)
                    if cached == nil {
                        let row = CharacterPartCache(bookID: bookID, chapter: chapter.id, start: part.start, end: part.start + part.text.utf16.count,
                                                     sourceRevision: plan.sourceRevision, sourceHash: hash, modelFingerprint: plan.modelFingerprint, promptVersion: 1, characters: people)
                        try row.validate(); try write(row, name: row.fileName, limit: 512 * 1024)
                    }
                    accumulator.add(chapter: chapter.id, characters: people)
                    checkpoint.completedParts += 1; try write(checkpoint, name: "checkpoint.json", limit: 16 * 1024)
                }
            }
            await progress(index + 1, plan.chapters.count, chapter.title)
        }
        try await validate(); try validatePlan(plan, active: true)
        let result = BookCharacterGuide(bookID: bookID, generationID: plan.generationID, sourceRevision: plan.sourceRevision,
                                        modelFingerprint: plan.modelFingerprint, modelLabel: plan.modelLabel, promptVersion: 1, sourceThrough: plan.sourceThrough,
                                        scannedChapters: plan.chapters.count, sourceCharacters: plan.sourceCharacters, characters: accumulator.characters, createdAt: Date())
        try result.validate(); try write(result, name: "guide.json", limit: 128 * 1024 * 1024)
        // The published generation makes this checkpoint inert even if cleanup is interrupted.
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("checkpoint.json"))
        return result
    }
    @MainActor private func validateDuringGeneration(_ plan: BookCharactersPlan) throws -> Book { try validatePlan(plan, active: true) }
    private func cachedCharacters(chapter: Int, part: KnowledgePart, plan: BookCharactersPlan, hash: String) throws -> [KnowledgeCharacter]? {
        guard let row: CharacterPartCache = try read("part-\(chapter)-\(part.start).json", limit: 512 * 1024), row.bookID == bookID, row.chapter == chapter,
              row.start == part.start, row.end == part.start + part.text.utf16.count, row.sourceRevision == plan.sourceRevision,
              row.sourceHash == hash, row.modelFingerprint == plan.modelFingerprint else { return nil }
        try row.validate(); try ChapterKnowledge.validateCharacters(row.characters, part: part)
        return row.characters
    }
    public func locate(_ guide: BookCharacterGuide, evidence: CharacterEvidence) throws -> SourcePassage {
        let book = try library.book(bookID)
        guard guide.bookID == bookID, guide.visible(in: book), guide.characters.contains(where: { $0.evidence.contains(evidence) }) else {
            throw MoReadError.invalid("人物资料的来源范围已变化，请重新提取。")
        }
        let chapter = try library.chapter(evidence.chapter, in: book)
        guard evidence.fact.matches(chapter.text) else { throw MoReadError.invalid("无法核对这条人物原文。") }
        return SourcePassage(bookID: bookID, chapter: chapter, offset: evidence.fact.start, text: evidence.fact.quote)
    }
    @MainActor public func delete() throws {
        guard !Self.active.contains(directory) else { throw MoReadError.invalid("请先停止人物提取。") }
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return }
        let empty = directory.deletingLastPathComponent().appendingPathComponent(".characters-delete-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: empty) }
        try LibraryStore.swapDirectories(directory, empty)
        try manager.removeItem(at: empty)
    }
    public func validateBackup() throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return }
        let book = try library.book(bookID), saved = try guide()
        let revision = MemoryBookScope.fingerprint(book.chapters.map(\.revision))
        _ = try checkpoint()
        var loaded: [Int: Chapter] = [:]
        func chapter(_ index: Int) throws -> Chapter {
            if let value = loaded[index] { return value }
            let value = try library.chapter(index, in: book)
            // Keep only one source chapter while validating a large book.
            loaded = [index: value]; return value
        }
        for url in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            if ["guide.json", "checkpoint.json"].contains(url.lastPathComponent) { continue }
            guard url.lastPathComponent.hasPrefix("part-"), url.pathExtension == "json",
                  let row: CharacterPartCache = try read(url.lastPathComponent, limit: 512 * 1024), row.fileName == url.lastPathComponent, row.bookID == bookID else {
                throw MoReadError.invalid("备份包含无法识别的人物缓存。")
            }
            try row.validate()
            if book.hasBody, row.sourceRevision == revision {
                let source = try chapter(row.chapter).text
                guard row.end <= source.utf16.count, TextBoundary.floor(row.start, in: source) == row.start, TextBoundary.floor(row.end, in: source) == row.end else { throw MoReadError.invalid("人物缓存超出原文范围。") }
                let part = KnowledgePart(start: row.start, text: (source as NSString).substring(with: NSRange(location: row.start, length: row.end - row.start)))
                guard ChapterKnowledgeEntry.hash(part.text) == row.sourceHash else { throw MoReadError.invalid("人物缓存与原文不一致。") }
                try ChapterKnowledge.validateCharacters(row.characters, part: part)
            }
        }
        if let saved, saved.visible(in: book) {
            let scope = saved.sourceThrough.map(ReadingScope.init(through:)) ?? .wholeBook
            for person in saved.characters {
                for evidence in person.evidence {
                    let text = scope.readableText(try chapter(evidence.chapter))
                    guard evidence.fact.matches(text), (text as NSString).range(of: person.name, options: .literal).location != NSNotFound else { throw MoReadError.invalid("人物资料与原文不一致。") }
                }
            }
        }
    }
    private func read<T: Decodable>(_ name: String, limit: Int) throws -> T? {
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(T.self, from: CharacterCardImporter.read(url, limit: limit))
    }
    private func write<T: Encodable>(_ value: T, name: String, limit: Int) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= limit else { throw MoReadError.invalid("人物资料超出保存大小上限。") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Task.checkCancellation(); try data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }
}
