import Foundation

public struct CharacterEvidence: Codable, Hashable, Sendable {
    public let chapter: Int
    public let fact: KnowledgeFact
}
public struct BookCharacterAttribute: Codable, Hashable, Sendable {
    public let kind: CharacterAttributeKind
    public let value: String
    public let evidence: CharacterEvidence
}
public struct BookCharacterRelationship: Codable, Hashable, Sendable {
    public let target: String
    public var sourceTarget: String? = nil
    public let relation: String
    public let evidence: CharacterEvidence
}
public struct BookCharacter: Codable, Equatable, Identifiable, Sendable {
    public var id: String { sourceName ?? name }
    public let name: String
    public let evidence: [CharacterEvidence]
    public var manualDescription: String? = nil
    public var sourceName: String? = nil
    public var attributes: [BookCharacterAttribute] = []
    public var relationships: [BookCharacterRelationship] = []
    public var aliases: [String] { attributes.filter { $0.kind == .alias }.map(\.value) }
    var verifiedNames: [String] { [id] + aliases }
    var profileEvidence: [CharacterEvidence] { attributes.map(\.evidence) + relationships.map(\.evidence) }
    var allEvidence: [CharacterEvidence] { evidence + profileEvidence }
    var cardDescription: String {
        let profile = attributes.map { ("\($0.kind.title)：\($0.value)", $0.evidence) } + relationships.map { ("\(name) → \($0.target)：\($0.relation)", $0.evidence) }
        return (profile.map { "\($0.0)\n（第 \($0.1.chapter + 1) 章依据：\($0.1.fact.quote)）" } + [editableDescription]).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
    public var editableDescription: String {
        manualDescription ?? evidence.map { "\($0.fact.text)\n（第 \($0.chapter + 1) 章依据：\($0.fact.quote)）" }.joined(separator: "\n\n")
    }
}
extension BookCharacter {
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name); evidence = try values.decode([CharacterEvidence].self, forKey: .evidence)
        manualDescription = try values.decodeIfPresent(String.self, forKey: .manualDescription); sourceName = try values.decodeIfPresent(String.self, forKey: .sourceName)
        attributes = try values.decodeIfPresent([BookCharacterAttribute].self, forKey: .attributes) ?? []
        relationships = try values.decodeIfPresent([BookCharacterRelationship].self, forKey: .relationships) ?? []
    }
}
public struct BookCharacterGuide: Codable, Equatable, Sendable {
    static let currentPromptVersion = 2
    public let bookID: UUID
    public let generationID: UUID
    public let sourceRevision: String
    public let modelFingerprint: String
    public let modelLabel: String
    public let promptVersion: Int
    public let sourceThrough: ReadingPosition?
    public let scannedChapters: Int
    public let sourceCharacters: Int64
    public var characters: [BookCharacter]
    public let createdAt: Date
    public var progressBounded: Bool { sourceThrough != nil }
    public func visible(in book: Book) -> Bool {
        book.id == bookID && !book.removed && book.hasBody && sourceRevision == MemoryBookScope.fingerprint(book.chapters.map(\.revision)) &&
        (sourceThrough.map { $0 <= book.readThrough } ?? true) && (try? validate()) != nil
    }
    public func displayedCharacters(in book: Book) -> [BookCharacter] {
        guard book.id == bookID, !book.removed, book.hasBody, (try? validate()) != nil else { return [] }
        if visible(in: book) { return characters }
        return characters.filter { $0.manualDescription != nil }.map {
            BookCharacter(name: $0.name, evidence: [], manualDescription: $0.manualDescription, sourceName: $0.id)
        }
    }
    func validate() throws {
        guard (1...BookCharacterGuide.currentPromptVersion).contains(promptVersion), ChapterKnowledgeEntry.validHash(sourceRevision), ChapterKnowledgeEntry.validHash(modelFingerprint),
              !modelLabel.isEmpty, modelLabel.utf16.count <= 500,
              (scannedChapters > 0 && sourceCharacters > 0) || (scannedChapters == 0 && sourceCharacters == 0 && characters.allSatisfy { $0.manualDescription != nil }),
              sourceThrough.map({ $0.chapter >= 0 && $0.offset >= 0 }) ?? true,
              Set(characters.map(\.name)).count == characters.count, Set(characters.map(\.id)).count == characters.count, createdAt.timeIntervalSince1970.isFinite else {
            throw MoReadError.invalid("人物资料的来源记录无效。")
        }
        for person in characters {
            guard !person.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, person.name.utf16.count <= 80,
                  !person.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, person.id.utf16.count <= 80,
                  person.manualDescription.map({ $0.utf16.count <= 24_000 }) ?? (ChapterKnowledge.validName(person.name) && !person.evidence.isEmpty),
                  person.sourceName == nil || person.manualDescription != nil, person.evidence.count <= 16 else { throw MoReadError.invalid("人物资料的名称、描述或依据数量无效。") }
            for attribute in person.attributes {
                try KnowledgeCharacterAttribute(kind: attribute.kind, value: attribute.value, fact: attribute.evidence.fact).validate(names: person.verifiedNames)
            }
            for relationship in person.relationships {
                let targetNames = [relationship.sourceTarget ?? relationship.target]
                guard targetNames.allSatisfy(ChapterKnowledge.validName) else { throw MoReadError.invalid("人物关系中的原名称无效。") }
                try KnowledgeCharacterRelationship(target: relationship.target, relation: relationship.relation, fact: relationship.evidence.fact).validate(names: person.verifiedNames, targetNames: targetNames)
            }
            for evidence in person.allEvidence {
                try evidence.fact.validate(sourceEnd: Int.max)
                guard evidence.chapter >= 0, sourceThrough.map({ ReadingScope(through: $0).allows(chapter: evidence.chapter, range: NSRange(location: evidence.fact.start, length: evidence.fact.end - evidence.fact.start)) }) ?? true else {
                    throw MoReadError.invalid("人物依据超出资料的阅读范围。")
                }
            }
        }
    }
    static func mergingManual(_ generated: [BookCharacter], previous: [BookCharacter]) -> [BookCharacter] {
        let edits = previous.filter { $0.manualDescription != nil }
        var result = generated.compactMap { person -> BookCharacter? in
            if let edit = edits.first(where: { $0.id == person.id }) {
                return BookCharacter(name: edit.name, evidence: person.evidence, manualDescription: edit.manualDescription, sourceName: edit.id, attributes: person.attributes, relationships: person.relationships)
            }
            return edits.contains(where: { $0.name.caseInsensitiveCompare(person.name) == .orderedSame }) ? nil : person
        }
        for edit in edits where !result.contains(where: { $0.id == edit.id }) {
            result.removeAll { $0.name.caseInsensitiveCompare(edit.name) == .orderedSame }
            result.append(BookCharacter(name: edit.name, evidence: [], manualDescription: edit.manualDescription, sourceName: edit.id))
        }
        return result
    }
}

struct BookCharacterAccumulator {
    private var names: [String] = []
    private var people: [String: BookCharacter] = [:]
    private static func distinct<T, Key: Hashable>(_ values: [T], by key: (T) -> Key) -> [T] {
        var seen: Set<Key> = []; return values.filter { seen.insert(key($0)).inserted }
    }
    private static func retained(_ values: [CharacterEvidence]) -> [CharacterEvidence] {
        let sorted = distinct(values, by: { $0.fact.text }).sorted { $0.chapter == $1.chapter ? $0.fact.start < $1.fact.start : $0.chapter < $1.chapter }
        return sorted.count <= 16 ? sorted : Array(sorted.prefix(4)) + sorted.suffix(12)
    }
    mutating func add(chapter: Int, characters: [KnowledgeCharacter]) {
        for person in characters {
            let previous = people[person.name]
            if previous == nil { names.append(person.name) }
            people[person.name] = BookCharacter(name: person.name,
                evidence: Self.retained((previous?.evidence ?? []) + person.facts.map { .init(chapter: chapter, fact: $0) }),
                attributes: Array(Self.distinct((previous?.attributes ?? []) + person.attributes.map { .init(kind: $0.kind, value: $0.value, evidence: .init(chapter: chapter, fact: $0.fact)) }, by: { [$0.kind.rawValue, $0.value] }).suffix(48)),
                relationships: Array(Self.distinct((previous?.relationships ?? []) + person.relationships.map { .init(target: $0.target, relation: $0.relation, evidence: .init(chapter: chapter, fact: $0.fact)) }, by: { [$0.target, $0.relation] }).suffix(96)))
        }
    }
    var characters: [BookCharacter] {
        var owners: [String: Set<String>] = [:]
        for person in people.values { for alias in person.aliases { owners[alias, default: []].insert(person.name) } }
        let canonical = Dictionary(uniqueKeysWithValues: names.map { name in
            let owner = owners[name]?.count == 1 ? owners[name]?.first : nil
            return (name, owner.flatMap { $0 != name && owners[$0] == nil ? $0 : nil } ?? name)
        })
        let ordered = Self.distinct(names.map { canonical[$0] ?? $0 }, by: { $0 })
        let grouped = Dictionary(grouping: names.compactMap { people[$0] }, by: { canonical[$0.name] ?? $0.name })
        return ordered.map { name in
            let rows = grouped[name] ?? []
            let relationships = rows.flatMap(\.relationships).map { item in
                BookCharacterRelationship(target: canonical[item.target] ?? item.target, sourceTarget: canonical[item.target].flatMap { $0 != item.target ? item.target : nil }, relation: item.relation, evidence: item.evidence)
            }.filter { $0.target != name }
            return BookCharacter(name: name, evidence: Self.retained(rows.flatMap(\.evidence)),
                attributes: Self.distinct(rows.flatMap(\.attributes), by: { [$0.kind.rawValue, $0.value] }),
                relationships: Self.distinct(relationships, by: { [$0.target, $0.relation] }))
        }
    }
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
        guard (1...BookCharacterGuide.currentPromptVersion).contains(promptVersion), completedParts >= 0, ChapterKnowledgeEntry.validHash(sourceRevision), ChapterKnowledgeEntry.validHash(modelFingerprint),
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
        guard chapter >= 0, start >= 0, end > start, end - start <= 10_000, (1...BookCharacterGuide.currentPromptVersion).contains(promptVersion),
              ChapterKnowledgeEntry.validHash(sourceRevision), ChapterKnowledgeEntry.validHash(sourceHash), ChapterKnowledgeEntry.validHash(modelFingerprint), characters.count <= 24 else {
            throw MoReadError.invalid("人物分段缓存的来源记录无效。")
        }
        for person in characters {
            guard ChapterKnowledge.validName(person.name), (1...4).contains(person.facts.count) else { throw MoReadError.invalid("人物缓存内容无效。") }
            guard person.attributes.count <= 12, person.relationships.count <= 12 else { throw MoReadError.invalid("人物属性或关系过多。") }
            try person.validateProfile()
            for fact in person.allFacts { try fact.validate(sourceEnd: end); guard fact.start >= start else { throw MoReadError.invalid("人物依据超出分段范围。") } }
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
    public func displayedCharacters(from expected: BookCharacterGuide) throws -> [BookCharacter] {
        guard try guide() == expected else { throw MoReadError.invalid("人物资料已变化，请重新打开。") }
        return expected.displayedCharacters(in: try library.book(bookID))
    }
    @MainActor @discardableResult public func saveCharacter(expected: BookCharacterGuide?, originalIdentity: String?, name: String, description: String) throws -> BookCharacterGuide {
        let book = try library.book(bookID), current = try guide()
        guard !book.removed, book.hasBody, current == expected else { throw MoReadError.invalid("人物资料已变化，请重新打开编辑。") }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines), description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf16.count <= 80, description.utf16.count <= 24_000 else { throw MoReadError.invalid("姓名最多 80 字，人物资料最多 24000 字。") }
        let original = originalIdentity.flatMap { id in current?.displayedCharacters(in: book).first { $0.id == id } }
        guard originalIdentity == nil || original != nil else { throw MoReadError.invalid("人物来源已变化，请重新提取或新建人物。") }
        var result = current ?? BookCharacterGuide(bookID: bookID, generationID: UUID(), sourceRevision: MemoryBookScope.fingerprint(book.chapters.map(\.revision)),
            modelFingerprint: ChapterKnowledgeEntry.hash("manual"), modelLabel: "手动整理", promptVersion: BookCharacterGuide.currentPromptVersion, sourceThrough: book.readThrough,
            scannedChapters: 0, sourceCharacters: 0, characters: [], createdAt: Date())
        guard !result.characters.contains(where: { person in
            person.id != originalIdentity && (person.name.caseInsensitiveCompare(name) == .orderedSame || person.id.caseInsensitiveCompare(name) == .orderedSame)
        }) else { throw MoReadError.invalid("已有同名人物，请编辑已有资料。") }
        let value = BookCharacter(name: name, evidence: original?.evidence ?? [], manualDescription: description, sourceName: original?.id ?? name, attributes: original?.attributes ?? [], relationships: original?.relationships ?? [])
        if let index = result.characters.firstIndex(where: { $0.id == originalIdentity }) { result.characters[index] = value }
        else { result.characters.append(value) }
        try result.validate(); try write(result, name: "guide.json", limit: 128 * 1024 * 1024)
        return result
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
            value.promptVersion == BookCharacterGuide.currentPromptVersion && value.generationID != saved?.generationID && value.sourceRevision == revision && value.modelFingerprint == modelFingerprint && value.sourceThrough == through ? value : nil
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
                                                 modelFingerprint: plan.modelFingerprint, sourceThrough: plan.sourceThrough, promptVersion: BookCharacterGuide.currentPromptVersion, completedParts: 0)
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
                                                     sourceRevision: plan.sourceRevision, sourceHash: hash, modelFingerprint: plan.modelFingerprint, promptVersion: BookCharacterGuide.currentPromptVersion, characters: people)
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
                                        modelFingerprint: plan.modelFingerprint, modelLabel: plan.modelLabel, promptVersion: BookCharacterGuide.currentPromptVersion, sourceThrough: plan.sourceThrough,
                                        scannedChapters: plan.chapters.count, sourceCharacters: plan.sourceCharacters,
                                        characters: BookCharacterGuide.mergingManual(accumulator.characters, previous: try guide()?.characters ?? []), createdAt: Date())
        try result.validate(); try write(result, name: "guide.json", limit: 128 * 1024 * 1024)
        // The published generation makes this checkpoint inert even if cleanup is interrupted.
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("checkpoint.json"))
        return result
    }
    @MainActor private func validateDuringGeneration(_ plan: BookCharactersPlan) throws -> Book { try validatePlan(plan, active: true) }
    private func cachedCharacters(chapter: Int, part: KnowledgePart, plan: BookCharactersPlan, hash: String) throws -> [KnowledgeCharacter]? {
        guard let row: CharacterPartCache = try read("part-\(chapter)-\(part.start).json", limit: 512 * 1024), row.bookID == bookID, row.chapter == chapter,
              row.start == part.start, row.end == part.start + part.text.utf16.count, row.sourceRevision == plan.sourceRevision,
              row.sourceHash == hash, row.modelFingerprint == plan.modelFingerprint, row.promptVersion == BookCharacterGuide.currentPromptVersion else { return nil }
        try row.validate(); try ChapterKnowledge.validateCharacters(row.characters, part: part)
        return row.characters
    }
    public func locate(_ guide: BookCharacterGuide, evidence: CharacterEvidence) throws -> SourcePassage {
        let book = try library.book(bookID)
        guard guide.bookID == bookID, guide.visible(in: book), guide.characters.contains(where: { $0.allEvidence.contains(evidence) }) else {
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
                for evidence in person.allEvidence {
                    let text = scope.readableText(try chapter(evidence.chapter))
                    guard evidence.fact.matches(text), person.verifiedNames.contains(where: { (text as NSString).range(of: $0, options: .literal).location != NSNotFound }) else { throw MoReadError.invalid("人物资料与原文不一致。") }
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
