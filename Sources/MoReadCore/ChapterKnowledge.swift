import Foundation
import CryptoKit

public struct KnowledgePart: Sendable {
    public let start: Int
    public let text: String
    public static func split(_ source: String, enforceChapterLimit: Bool = true) throws -> [Self] {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !enforceChapterLimit || source.utf16.count <= 60_000 else {
            throw MoReadError.invalid("每章最多整理 60000 字已读内容。")
        }
        let text = source as NSString, punctuation = Set("\n。！？.!?".utf16)
        var parts: [Self] = [], start = 0
        while start < text.length {
            var end = TextBoundary.floor(min(start + 10_000, text.length), in: source)
            if end < text.length, let boundary = stride(from: end - 1, through: start + 5_000, by: -1).first(where: { punctuation.contains(text.character(at: $0)) }) { end = boundary + 1 }
            parts.append(Self(start: start, text: text.substring(with: NSRange(location: start, length: end - start))))
            start = end
        }
        return parts
    }
}

public struct KnowledgeFact: Codable, Hashable, Sendable {
    public let text: String
    public let quote: String
    public let start: Int
    public let end: Int
    func validate(sourceEnd: Int) throws {
        guard (1...600).contains(text.utf16.count), (4...300).contains(quote.utf16.count),
              start >= 0, end > start, end <= sourceEnd, end - start == quote.utf16.count else {
            throw MoReadError.invalid("提纲的原文依据无效。")
        }
    }
    func matches(_ source: String) -> Bool {
        start >= 0 && end > start && end <= source.utf16.count && TextBoundary.floor(start, in: source) == start && TextBoundary.floor(end, in: source) == end &&
        (source as NSString).substring(with: NSRange(location: start, length: end - start)).utf16.elementsEqual(quote.utf16)
    }
}

public struct KnowledgeCharacter: Codable, Hashable, Sendable {
    public let name: String
    public let facts: [KnowledgeFact]
}

public struct ChapterKnowledge: Codable, Equatable, Sendable {
    public let outline: String
    public let summary: [KnowledgeFact]
    public let characters: [KnowledgeCharacter]
    public var facts: [KnowledgeFact] { summary + characters.flatMap(\.facts) }
    private struct Draft: Decodable {
        struct Fact: Decodable { let text: String; let quote: String }
        struct Character: Decodable { let name: String; let facts: [Fact] }
        let outline: String
        let summary: [Fact]
        let characters: [Character]?
    }
    public static func validateOutline(_ value: String, limit: Int = 2400) throws -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf16.count <= limit else { throw MoReadError.invalid("请生成长度适中的章节梗概。") }
        guard text.range(of: #"(?m)^\s*(?:[-*•]|[0-9]+[.)、])\s+"#, options: .regularExpression) == nil else {
            throw MoReadError.invalid("章节梗概要写成连贯自然段，请勿罗列要点。")
        }
        return text
    }
    public static func parse(_ raw: String, part: KnowledgePart, maximumOutline: Int = 2400) throws -> Self {
        guard raw.utf16.count <= 64_000, part.start >= 0, part.start <= 60_000, part.text.utf16.count <= 60_000 - part.start else {
            throw MoReadError.invalid("整理结果或原文范围过长。")
        }
        guard let draft = try? JSONDecoder().decode(Draft.self, from: jsonData(raw)),
              (1...8).contains(draft.summary.count), (draft.characters ?? []).count <= 16 else {
            throw MoReadError.invalid("整理结果格式不完整或条目过多，请重试。")
        }
        return Self(outline: try validateOutline(draft.outline, limit: maximumOutline), summary: try draft.summary.map { try verify($0, part: part) },
                    characters: try verifyCharacters(draft.characters ?? [], part: part))
    }
    public static func parseCharacters(_ raw: String, part: KnowledgePart) throws -> [KnowledgeCharacter] {
        struct Characters: Decodable { let characters: [Draft.Character] }
        guard part.start >= 0, part.text.utf16.count <= 10_000, part.start <= Int.max - part.text.utf16.count,
              let draft = try? JSONDecoder().decode(Characters.self, from: jsonData(raw)), draft.characters.count <= 24 else {
            throw MoReadError.invalid("人物资料格式无效或条目过多。")
        }
        return try verifyCharacters(draft.characters, part: part)
    }
    static func jsonData(_ raw: String) throws -> Data {
        guard raw.utf16.count <= 64_000 else { throw MoReadError.invalid("整理结果过长。") }
        var clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("```json") { clean.removeFirst(7) } else if clean.hasPrefix("```") { clean.removeFirst(3) }
        if clean.hasSuffix("```") { clean.removeLast(3) }
        return Data(clean.utf8)
    }
    private static func verify(_ fact: Draft.Fact, part: KnowledgePart) throws -> KnowledgeFact {
        let text = fact.text.trimmingCharacters(in: .whitespacesAndNewlines), quote = fact.quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...600).contains(text.utf16.count), (4...300).contains(quote.utf16.count) else { throw MoReadError.invalid("整理结果缺少简短描述或原文依据。") }
        let source = part.text as NSString, found = source.range(of: quote, options: .literal)
        // Search again one UTF-16 unit later to catch overlapping repetitions as well.
        guard found.location != NSNotFound,
              source.range(of: quote, options: .literal, range: NSRange(location: found.location + 1, length: source.length - found.location - 1)).location == NSNotFound else {
            throw MoReadError.invalid("部分引文无法唯一核对，请重新整理。")
        }
        return KnowledgeFact(text: text, quote: quote, start: part.start + found.location, end: part.start + found.location + found.length)
    }
    private static func verifyCharacters(_ characters: [Draft.Character], part: KnowledgePart) throws -> [KnowledgeCharacter] {
        try characters.map { character in
            let name = character.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard validName(name), (1...4).contains(character.facts.count), (part.text as NSString).range(of: name, options: .literal).location != NSNotFound else {
                throw MoReadError.invalid("人物名称或原文依据无效，请使用原文中的人名或稳定称呼。")
            }
            return KnowledgeCharacter(name: name, facts: try character.facts.map { try verify($0, part: part) })
        }
    }
    static func validateCharacters(_ characters: [KnowledgeCharacter], part: KnowledgePart) throws {
        guard characters.count <= 24 else { throw MoReadError.invalid("单段人物条目过多。") }
        let drafts = characters.map { Draft.Character(name: $0.name, facts: $0.facts.map { Draft.Fact(text: $0.text, quote: $0.quote) }) }
        guard try verifyCharacters(drafts, part: part) == characters else { throw MoReadError.invalid("缓存中的人物依据与原文不一致。") }
    }
    public static func merge(_ parts: [Self], outline: String? = nil) throws -> Self {
        guard !parts.isEmpty, parts.count <= 12 else { throw MoReadError.invalid("章节整理分段不完整。") }
        guard parts.count == 1 || outline != nil else { throw MoReadError.invalid("长章节还需要合成完整梗概。") }
        func unique<T: Hashable>(_ values: [T]) -> [T] { var seen: Set<T> = []; return values.filter { seen.insert($0).inserted } }
        let names = unique(parts.flatMap { $0.characters.map(\.name) })
        return Self(outline: try validateOutline(outline ?? parts[0].outline), summary: unique(parts.flatMap(\.summary)),
                    characters: names.map { name in KnowledgeCharacter(name: name, facts: unique(parts.flatMap(\.characters).filter { $0.name == name }.flatMap(\.facts))) })
    }
    static func validName(_ name: String) -> Bool {
        (1...60).contains(name.utf16.count) && !["他", "她", "我", "你", "他们", "她们", "旁白"].contains(name)
    }
    func validate(sourceEnd: Int) throws {
        _ = try Self.validateOutline(outline)
        guard (1...96).contains(summary.count), characters.count <= 192,
              characters.allSatisfy({ Self.validName($0.name) && (1...48).contains($0.facts.count) }) else {
            throw MoReadError.invalid("章节提纲条目数量或人物格式无效。")
        }
        for fact in facts { try fact.validate(sourceEnd: sourceEnd) }
    }
}

public struct KnowledgeSource: Sendable {
    public let bookID: UUID
    public let bookTitle: String
    public let chapter: Int
    public let chapterTitle: String
    public let text: String
    public let chapterLength: Int
    public let revision: String
    public let parts: [KnowledgePart]
    public var partial: Bool { text.utf16.count < chapterLength }
    public var requestCount: Int { parts.count + (parts.count > 1 ? 1 : 0) }
    public var maximumRequests: Int { requestCount * 2 }
}

public struct ChapterKnowledgeEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: Int { chapter }
    public let bookID: UUID
    public let chapter: Int
    public let sourceRevision: String
    public let sourceEnd: Int
    public let sourceHash: String
    public let modelFingerprint: String
    public let modelLabel: String
    public let promptVersion: Int
    public let content: ChapterKnowledge
    public let createdAt: Date
    public func validate() throws {
        guard chapter >= 0, (1...60_000).contains(sourceEnd), promptVersion == 2,
              Self.validHash(sourceRevision), Self.validHash(sourceHash), Self.validHash(modelFingerprint), !modelLabel.isEmpty, modelLabel.utf16.count <= 500,
              createdAt.timeIntervalSince1970.isFinite else { throw MoReadError.invalid("章节提纲的来源记录无效。") }
        try content.validate(sourceEnd: sourceEnd)
    }
    public func visible(in book: Book, revision: String? = nil) -> Bool {
        book.id == bookID && !book.removed && book.hasBody && book.chapters.indices.contains(chapter) &&
        sourceRevision == (revision ?? MemoryBookScope.fingerprint(book.chapters.map(\.revision))) &&
        ReadingScope(through: book.readThrough).allows(chapter: chapter, range: NSRange(location: 0, length: sourceEnd)) &&
        (try? validate()) != nil
    }
    static func validHash(_ value: String) -> Bool { value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    static func hash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
}

extension LibraryStore {
    /// Freezes only the already-read prefix. Preparing this value never contacts a service.
    public func knowledgeSource(bookID: UUID, chapter index: Int) throws -> KnowledgeSource {
        let book = try book(bookID)
        guard !book.removed, book.hasBody else { throw MoReadError.invalid("书籍正文已移除。") }
        let chapter = try chapter(index, in: book)
        let text = ReadingScope(through: book.readThrough).readableText(chapter)
        let parts = try KnowledgePart.split(text).filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return KnowledgeSource(bookID: bookID, bookTitle: book.title, chapter: index, chapterTitle: chapter.title,
                               text: text, chapterLength: chapter.text.utf16.count, revision: MemoryBookScope.fingerprint(book.chapters.map(\.revision)), parts: parts)
    }
    @discardableResult public func validateKnowledgeSource(_ source: KnowledgeSource) throws -> Book {
        try Task.checkCancellation()
        let book = try book(source.bookID)
        guard !book.removed, book.hasBody, source.revision == MemoryBookScope.fingerprint(book.chapters.map(\.revision)),
              ReadingScope(through: book.readThrough).allows(chapter: source.chapter, range: NSRange(location: 0, length: source.text.utf16.count)) else {
            throw MoReadError.invalid("正文或已读范围已变化，请重新整理。")
        }
        let current = try chapter(source.chapter, in: book)
        guard current.text.utf16.count == source.chapterLength, TextBoundary.prefix(current.text, end: source.text.utf16.count) == source.text else {
            throw MoReadError.invalid("章节原文已变化，请重新整理。")
        }
        return book
    }
    @discardableResult public func saveKnowledge(_ content: ChapterKnowledge, source: KnowledgeSource, modelFingerprint: String, modelLabel: String) throws -> ChapterKnowledgeEntry {
        let book = try validateKnowledgeSource(source)
        let entry = ChapterKnowledgeEntry(bookID: book.id, chapter: source.chapter, sourceRevision: source.revision,
                                          sourceEnd: source.text.utf16.count, sourceHash: ChapterKnowledgeEntry.hash(source.text),
                                          modelFingerprint: modelFingerprint, modelLabel: modelLabel, promptVersion: 2, content: content, createdAt: Date())
        try entry.validate()
        guard content.facts.allSatisfy({ $0.matches(source.text) }), content.characters.allSatisfy({ (source.text as NSString).range(of: $0.name, options: .literal).location != NSNotFound }) else {
            throw MoReadError.invalid("提纲原文依据与本章不一致，旧提纲保持不变。")
        }
        try Task.checkCancellation()
        try modifyRecords(for: book) { records in
            var entries = records.chapterKnowledge ?? []
            entries.removeAll { $0.chapter == source.chapter }; entries.append(entry)
            records.chapterKnowledge = entries.sorted { $0.chapter < $1.chapter }
        }
        return entry
    }
    @discardableResult public func validateKnowledge(_ entry: ChapterKnowledgeEntry) throws -> Chapter {
        let book = try book(entry.bookID)
        guard entry.visible(in: book) else { throw MoReadError.invalid("阅读范围或提纲来源已变化，请重新整理。") }
        let chapter = try chapter(entry.chapter, in: book)
        let source = TextBoundary.prefix(chapter.text, end: entry.sourceEnd)
        guard source.utf16.count == entry.sourceEnd, ChapterKnowledgeEntry.hash(source) == entry.sourceHash,
              entry.content.facts.allSatisfy({ $0.matches(source) }),
              entry.content.characters.allSatisfy({ (source as NSString).range(of: $0.name, options: .literal).location != NSNotFound }) else {
            throw MoReadError.invalid("原文已变化，无法核对提纲依据。")
        }
        return chapter
    }
    public func locateKnowledge(_ entry: ChapterKnowledgeEntry, fact: KnowledgeFact) throws -> SourcePassage {
        guard entry.content.facts.contains(fact) else { throw MoReadError.invalid("这条依据不属于当前提纲。") }
        let chapter = try validateKnowledge(entry)
        return SourcePassage(bookID: entry.bookID, chapter: chapter, offset: fact.start, text: fact.quote)
    }
    public func deleteKnowledge(bookID: UUID, chapter: Int) throws {
        let book = try book(bookID)
        try modifyRecords(for: book) { $0.chapterKnowledge?.removeAll { $0.chapter == chapter } }
    }
}
