import Foundation

public struct VocabularyWord: Codable, Equatable, Identifiable, Sendable {
    public var id: String { word }
    public let word: String
    public var definition: String
    public var gloss: String
    public var phonetic: String
    public var learned: Bool
    public let source: SourcePassage?
    public let context: String
    public let createdAt: Date
    public init(word: String, definition: String, source: SourcePassage? = nil, context: String = "", gloss: String = "", phonetic: String = "") {
        self.word = Self.normalize(word); self.definition = definition
        self.source = source; self.gloss = gloss; self.phonetic = phonetic
        self.context = context.isEmpty ? source?.text ?? "" : context
        learned = false; createdAt = Date()
    }
    public static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "’", with: "'").lowercased()
    }
    fileprivate var valid: Bool {
        !word.isEmpty && word.count <= 80 && word == Self.normalize(word)
        && word.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
        && !word.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        && !definition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && definition.count <= 12_000
        && gloss.count <= 24 && phonetic.count <= 64 && context.count <= 12_000 && createdAt.timeIntervalSince1970.isFinite
        && source.map { $0.chapter >= 0 && $0.offset >= 0 && !$0.text.isEmpty && $0.text.count <= 12_000 && $0.revision.count <= 128 && ($0.epubLocator?.count ?? 0) <= 64 * 1024 } != false
    }
}

public struct VocabularyStore {
    private let file: URL
    public init(root: URL) { file = root.appendingPathComponent("vocabulary.json") }
    public func words() throws -> [VocabularyWord] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 32 * 1024 * 1024 else { throw MoReadError.invalid("生词本文件无效或过大。") }
        let words = try JSONDecoder().decode([VocabularyWord].self, from: Data(contentsOf: file))
        guard words.count <= 20_000, words.allSatisfy(\.valid), Set(words.map(\.word)).count == words.count else { throw MoReadError.invalid("生词本记录无效。") }
        return words.sorted { $0.createdAt == $1.createdAt ? $0.word < $1.word : $0.createdAt > $1.createdAt }
    }
    @discardableResult public func saveDefinition(word: String, definition: String, source: SourcePassage? = nil, context: String = "", gloss: String = "", phonetic: String = "") throws -> VocabularyWord {
        var words = try words()
        let key = VocabularyWord.normalize(word)
        var item = words.first { $0.word == key } ?? VocabularyWord(word: key, definition: definition, source: source, context: context)
        item.definition = String(definition.trimmingCharacters(in: .whitespacesAndNewlines).prefix(12_000))
        item.gloss = gloss.trimmingCharacters(in: .whitespacesAndNewlines)
        item.phonetic = phonetic.trimmingCharacters(in: .whitespacesAndNewlines)
        words.removeAll { $0.word == key }; words.append(item)
        try write(words); return item
    }
    public func update(_ item: VocabularyWord, replacing original: VocabularyWord) throws {
        var words = try words()
        guard item.word == original.word, item.source == original.source, item.context == original.context, item.createdAt == original.createdAt,
              let index = words.firstIndex(of: original) else { throw MoReadError.invalid("这个词已发生变化，请重新打开后编辑。") }
        words[index] = item; try write(words)
    }
    public func remove(_ original: VocabularyWord) throws {
        var words = try words()
        guard let index = words.firstIndex(of: original) else { throw MoReadError.invalid("这个词已发生变化，请重新打开后删除。") }
        words.remove(at: index); try write(words)
    }
    public func undo(_ original: VocabularyWord, after replacement: VocabularyWord?) throws {
        var words = try words()
        let current = words.first { $0.word == original.word }
        guard replacement.map({ $0.word == original.word }) ?? true, current == replacement else {
            throw MoReadError.invalid("这个词后来又发生了变化，无法撤销，请查看当前内容。")
        }
        words.removeAll { $0.word == original.word }; words.append(original)
        try write(words)
    }
    private func write(_ words: [VocabularyWord]) throws {
        guard words.count <= 20_000, words.allSatisfy(\.valid) else { throw MoReadError.invalid("生词、释义或读音超出范围，请检查后保存。") }
        let data = try JSONEncoder().encode(words)
        guard data.count <= 32 * 1024 * 1024 else { throw MoReadError.invalid("生词本已达到存储上限。") }
        try data.write(to: file, options: .atomic)
    }
}


public enum VocabularyFilter: String, CaseIterable, Sendable {
    case all, learning, learned
    public var label: String { switch self { case .all: "全部"; case .learning: "学习中"; case .learned: "已掌握" } }
    public func includes(_ word: VocabularyWord) -> Bool { self == .all || word.learned == (self == .learned) }
}

public struct VocabularyGroup: Identifiable, Sendable {
    public enum Period: Hashable, Sendable { case today, yesterday, week, month(Int, Int) }
    public var id: Period { period }
    public let period: Period
    public var words: [VocabularyWord]
    public static func groups(_ words: [VocabularyWord], query: String, filter: VocabularyFilter, now: Date = Date(), timeZone: TimeZone = .current) -> [Self] {
        let calendar = ReadingCalendar.calendar(timeZone: timeZone), today = calendar.startOfDay(for: now)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = words.filter { filter.includes($0) && $0.createdAt.timeIntervalSince1970.isFinite &&
            (needle.isEmpty || [$0.word, $0.gloss, $0.definition].contains { $0.localizedCaseInsensitiveContains(needle) })
        }.sorted { $0.createdAt == $1.createdAt ? $0.word < $1.word : $0.createdAt > $1.createdAt }
        var result: [Self] = [], indices: [Period: Int] = [:]
        for word in selected {
            let date = calendar.startOfDay(for: word.createdAt)
            let days = calendar.dateComponents([.day], from: date, to: today).day ?? 0
            let period: Period = days <= 0 ? .today : days == 1 ? .yesterday : days < 7 ? .week : .month(calendar.component(.year, from: date), calendar.component(.month, from: date))
            if let index = indices[period] { result[index].words.append(word) }
            else { indices[period] = result.count; result.append(.init(period: period, words: [word])) }
        }
        return result
    }
}

extension VocabularyWord {
    public var preview: String {
        var lines = definition.components(separatedBy: .newlines).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: #"^(#{1,6}\s+|>\s*|[-*+]\s+|\d+[.)]\s+)"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\*\*|__|`|~~"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        if lines.first?.caseInsensitiveCompare(word) == .orderedSame { lines.removeFirst() }
        let plain = lines.joined(separator: " ").replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return plain == gloss.trimmingCharacters(in: .whitespacesAndNewlines) ? "" : String(plain.prefix(200))
    }
    public func contextMatch(in text: String) -> Range<String.Index>? {
        guard !word.isEmpty else { return nil }
        return text.range(of: word, options: .caseInsensitive) ?? text.range(of: word.replacingOccurrences(of: "'", with: "’"), options: .caseInsensitive)
    }
}
