import Foundation

public struct CompanionSettings: Codable {
    public var knowledgeProvider: UUID?
    public var toolsEnabled: Bool?
    public var webSearch: WebSearchSettings?
    public var rerank: RerankSettings?
    public var personaMemory: PersonaMemorySettings?
    public var userMasks: UserMaskSettings?
    public var summarySettings: SummarySettings?
    public var proactive: ProactiveSettings?
    public var providers: [AIProvider] = []
    public var selectedProvider: UUID?
    public var selectedCharacter: UUID?
    public var userName = "读者"
    public var embeddingProvider: UUID?
    public var embeddingModel: String?
    public var vectorBooks: [UUID]?
    public init() {}
}

public struct Conversation: Codable, Identifiable, Hashable, Sendable {
    public var focusedBookIDs: [UUID]?
    public var id = UUID()
    public var title: String
    public var bookID: UUID?
    public var characterID: UUID
    public var summary: ConversationSummary?
    public var messages: [ChatMessage] = []
    public var sourceLimits: [UUID: ReadingPosition] = [:]
    public var sourceRevisions: [UUID: [String]] = [:]
    public var updatedAt = Date()
    public init(title: String, bookID: UUID?, characterID: UUID) {
        self.title = title; self.bookID = bookID; self.characterID = characterID
    }
    public func validateOrganizationPlans() throws {
        try validateFocus()
        for message in messages {
            for trace in message.toolTrace ?? [] {
                if let sources = trace.webSources {
                    guard WebSearchClient.tools.contains(trace.call.name), trace.state == "succeeded", message.role == "assistant", sources.count <= 8, Set(sources.map(\.url)).count == sources.count else { throw MoReadError.invalid("网页来源记录无效。") }
                    for source in sources { try source.validate() }
                }
                if let plan = trace.organizationPlan {
                    guard bookID == nil, trace.call.name == "propose_library_organization", trace.state == "succeeded", message.role == "assistant" else { throw MoReadError.invalid("整理方案的话题或工具记录无效。") }
                    _ = try plan.encoded()
                }
            }
        }
    }
    public func validateSources(books: [Book]) throws {
        for (id, end) in sourceLimits {
            guard let book = books.first(where: { $0.id == id }), !book.removed,
                  book.chapters.indices.contains(end.chapter), end.offset >= 0, end.offset <= book.chapters[end.chapter].length,
                  book.readThrough >= end, sourceRevisions[id] == book.chapters.map(\.revision) else {
                throw MoReadError.invalid("这个话题引用的书籍或已读范围发生了变化，请新建话题后继续。")
            }
        }
    }
}

public final class CompanionStore {
    private let root: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let manager = FileManager.default
    public init(root: URL) throws {
        self.root = root.appendingPathComponent("companion", isDirectory: true)
        try manager.createDirectory(at: self.root.appendingPathComponent("characters"), withIntermediateDirectories: true)
        try manager.createDirectory(at: self.root.appendingPathComponent("conversations"), withIntermediateDirectories: true)
    }
    public func settings() throws -> CompanionSettings {
        let url = root.appendingPathComponent("settings.json")
        return manager.fileExists(atPath: url.path) ? try decoder.decode(CompanionSettings.self, from: Data(contentsOf: url)) : CompanionSettings()
    }
    public func save(_ settings: CompanionSettings) throws { try encoder.encode(settings).write(to: root.appendingPathComponent("settings.json"), options: .atomic) }
    public func characters() throws -> [CharacterCard] {
        try manager.contentsOfDirectory(at: root.appendingPathComponent("characters"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { try decoder.decode(CharacterCard.self, from: Data(contentsOf: $0)) }.sorted { $0.name < $1.name }
    }
    public func save(_ card: CharacterCard) throws {
        try encoder.encode(card).write(to: root.appendingPathComponent("characters/\(card.id.uuidString).json"), options: .atomic)
    }
    public func conversations() throws -> [Conversation] {
        // ponytail: history loads one JSON per conversation; add a lightweight index if history opening becomes slow.
        try manager.contentsOfDirectory(at: root.appendingPathComponent("conversations"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { let value = try decoder.decode(Conversation.self, from: Data(contentsOf: $0)); try value.validateOrganizationPlans(); return value }.sorted { $0.updatedAt > $1.updatedAt }
    }
    public func save(_ conversation: Conversation) throws {
        try conversation.validateOrganizationPlans()
        try encoder.encode(conversation).write(to: root.appendingPathComponent("conversations/\(conversation.id.uuidString).json"), options: .atomic)
    }
    public func deleteConversation(_ id: UUID) throws { try manager.removeItem(at: root.appendingPathComponent("conversations/\(id.uuidString).json")) }
}

public struct CompanionContext: Sendable {
    public var text: String
    public var passages: [SourcePassage]
    public var limits: [UUID: ReadingPosition]
    public var revisions: [UUID: [String]]
    public var retrievalNotice: String?
    var retrievalPlan: HybridRetrieval.Plan?
    public init(text: String, passages: [SourcePassage], limits: [UUID: ReadingPosition], revisions: [UUID: [String]]) {
        self.text = text; self.passages = passages; self.limits = limits; self.revisions = revisions
    }
    public var rerankPassages: [SourcePassage] { retrievalPlan?.rerankPassages ?? passages }
    public func validateSources(books: [Book]) throws {
        if let plan = retrievalPlan { for book in plan.books { try ReaderTools.validate(book, current: books) } }
        for (id, end) in limits {
            guard let book = books.first(where: { $0.id == id }), !book.removed, book.hasBody,
                  book.readThrough >= end, revisions[id] == book.chapters.map(\.revision) else {
                throw MoReadError.invalid("书籍内容或阅读范围已变化，请重新发送。")
            }
        }
    }
    public mutating func applyRanking(_ passages: [SourcePassage], books: [Book], store: LibraryStore) throws {
        try validateSources(books: books)
        guard let plan = retrievalPlan else { order(passages, books: books); return }
        let selected = try HybridRetrieval.finish(plan, order: passages, store: store)
        limits = [:]; revisions = [:]
        for passage in selected {
            if let book = plan.books.first(where: { $0.id == passage.bookID }) { limits[book.id] = book.readThrough; revisions[book.id] = book.chapters.map(\.revision) }
        }
        order(selected, books: plan.books)
    }
    public mutating func order(_ passages: [SourcePassage], books: [Book]) {
        self.passages = passages
        text = passages.enumerated().map { index, passage in
            let book = books.first { $0.id == passage.bookID }
            let title = book?.chapters.first { $0.id == passage.chapter }?.title ?? ""
            return "【来源 \(index + 1)】《\(book?.title ?? "")》\(title)\n\(passage.text)"
        }.joined(separator: "\n\n")
        if let retrievalNotice { text = retrievalNotice + "\n\n" + text }
    }
}

public enum CompanionContextBuilder {
    public static func build(query: String, books: [Book], currentBook: UUID?, store: LibraryStore, selection: SourcePassage? = nil, semantic: [SourcePassage] = [], vector: [RetrievalCandidate] = [], firstChapter: Int = 0, lastChapter: Int = Int.max, topK: Int = 8, chapterOrder: Bool = false) throws -> CompanionContext {
        let plan = try HybridRetrieval.prepare(query: TextBoundary.prefix(query, end: 512), books: books, currentBook: currentBook, store: store, selection: selection, semantic: vector + semantic.map { RetrievalCandidate($0) }, firstChapter: max(0, firstChapter), lastChapter: lastChapter, topK: topK, chapterOrder: chapterOrder)
        let passages = try HybridRetrieval.finish(plan, store: store)
        var limits: [UUID: ReadingPosition] = [:], revisions: [UUID: [String]] = [:]
        for passage in passages {
            if let book = plan.books.first(where: { $0.id == passage.bookID }) { limits[book.id] = book.readThrough; revisions[book.id] = book.chapters.map(\.revision) }
        }
        var context = CompanionContext(text: "", passages: passages, limits: limits, revisions: revisions)
        context.retrievalPlan = plan; context.retrievalNotice = plan.notice
        context.order(passages, books: plan.books)
        return context
    }
}
