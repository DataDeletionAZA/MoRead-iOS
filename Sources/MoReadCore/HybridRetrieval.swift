import Foundation

public struct RetrievalCandidate: Sendable {
    public let passage: SourcePassage
    public var distance: Double?
    public var lexicalScore: Double?
    public var key: String { passage.id + ":\(passage.text.utf16.count)" }
    public init(_ passage: SourcePassage, distance: Double? = nil, lexicalScore: Double? = nil) {
        self.passage = passage; self.distance = distance; self.lexicalScore = lexicalScore
    }
}

public enum HybridRetrieval {
    private static let words = try! NSRegularExpression(pattern: "[a-z0-9]+|[\\p{Han}]+", options: .caseInsensitive)
    private static let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)
    public static func tokens(_ text: String) -> [String] {
        let text = text.lowercased(), source = text as NSString
        var tokens: [String] = []
        for match in words.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let value = source.substring(with: match.range)
            if value.unicodeScalars.first.map({ $0.isASCII }) == true { tokens.append(value); continue }
            let characters = Array(value.unicodeScalars)
            if characters.count == 1 { tokens.append(value) }
            if characters.count >= 2 {
                for size in 2...min(4, characters.count) {
                    for start in 0...(characters.count - size) { tokens.append(String(String.UnicodeScalarView(characters[start..<(start + size)]))) }
                }
            }
        }
        return tokens
    }
    static func segments(_ query: String) -> [String] { query.lowercased().components(separatedBy: separators).filter { $0.utf16.count >= 2 } }
    static func literalRatio(_ text: String, segments: [String]) -> Double {
        guard !segments.isEmpty else { return 0 }
        let text = text.lowercased()
        return Double(segments.filter { text.contains($0) }.count) / Double(segments.count)
    }
    public static func lexical(_ passages: [SourcePassage], query: String, limit: Int = 60) throws -> [RetrievalCandidate] {
        let terms = Set(tokens(TextBoundary.prefix(query, end: 512)))
        guard !passages.isEmpty, !terms.isEmpty, limit > 0 else { return [] }
        var documents: [(length: Int, frequencies: [String: Int])] = [], df: [String: Int] = [:], total = 0
        for passage in passages {
            try Task.checkCancellation()
            let tokens = tokens(passage.text)
            var counts: [String: Int] = [:]
            for token in tokens where terms.contains(token) { counts[token, default: 0] += 1 }
            for term in counts.keys { df[term, default: 0] += 1 }
            total += tokens.count; documents.append((tokens.count, counts))
        }
        let average = max(1, Double(total) / Double(passages.count)), count = Double(passages.count)
        var result: [RetrievalCandidate] = []
        for (index, stats) in documents.enumerated() {
            try Task.checkCancellation()
            var score = 0.0
            for term in stats.frequencies.keys.sorted() {
                let frequency = Double(stats.frequencies[term]!), documentFrequency = Double(df[term] ?? 0)
                let idf = log(1 + (count - documentFrequency + 0.5) / (documentFrequency + 0.5))
                score += idf * frequency * 2.2 / (frequency + 1.2 * (0.25 + 0.75 * Double(stats.length) / average))
            }
            if score > 0 { result.append(RetrievalCandidate(passages[index], lexicalScore: score)) }
        }
        return Array(result.sorted { lhs, rhs in
            if lhs.lexicalScore != rhs.lexicalScore { return lhs.lexicalScore! > rhs.lexicalScore! }
            return before(lhs.passage, rhs.passage)
        }.prefix(limit))
    }
    public static func fuse(vector: [RetrievalCandidate], lexical: [RetrievalCandidate], query: String) -> [RetrievalCandidate] {
        let meaningful = query.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
        let weight = meaningful <= 4 ? 2.0 : meaningful <= 8 ? 1.6 : meaningful <= 16 ? 1.3 : 1.0
        let segments = segments(query), rescueFloor = (lexical.compactMap(\.lexicalScore).max() ?? 0) * 0.35
        var scores: [String: Double] = [:], values: [String: RetrievalCandidate] = [:], order: [String] = []
        for (items, weight) in [(vector, 1.0), (lexical, weight)] {
            var seen = Set<String>()
            for (rank, item) in items.enumerated() where seen.insert(item.key).inserted {
                if values[item.key] == nil { values[item.key] = item; order.append(item.key) }
                if let distance = item.distance { values[item.key]?.distance = distance }
                if let score = item.lexicalScore { values[item.key]?.lexicalScore = score }
                scores[item.key, default: 0] += weight / (60 + Double(rank) + 1)
            }
        }
        for key in order { scores[key, default: 0] += literalRatio(values[key]!.passage.text, segments: segments) * 1.5 / 61 }
        return order.enumerated().filter { _, key in
            let value = values[key]!
            guard let distance = value.distance else { return true }
            return distance.isFinite && (distance <= 0.8 || literalRatio(value.passage.text, segments: segments) == 1 || (rescueFloor > 0 && (value.lexicalScore ?? 0) >= rescueFloor))
        }.sorted { lhs, rhs in
            scores[lhs.element] == scores[rhs.element] ? lhs.offset < rhs.offset : scores[lhs.element]! > scores[rhs.element]!
        }.map { values[$0.element]! }
    }
    public static func select(_ ranked: [RetrievalCandidate], query: String, topK: Int = 8) -> [RetrievalCandidate] {
        let topK = min(24, max(1, topK)), segments = segments(query)
        var picked = Set<String>(), chapters: [String: Int] = [:]
        func pick(_ item: RetrievalCandidate, quota: Int) {
            let chapter = "\(item.passage.bookID):\(item.passage.chapter)"
            guard picked.count < topK, !picked.contains(item.key), chapters[chapter, default: 0] < quota else { return }
            picked.insert(item.key); chapters[chapter, default: 0] += 1
        }
        for item in ranked where picked.count < min(2, topK) && literalRatio(item.passage.text, segments: segments) == 1 { pick(item, quota: 2) }
        for item in ranked { pick(item, quota: 2) }
        if picked.count < topK { for item in ranked { pick(item, quota: 3) } }
        return ranked.filter { picked.contains($0.key) }
    }
    static func before(_ a: SourcePassage, _ b: SourcePassage) -> Bool {
        if a.bookID != b.bookID { return a.bookID.uuidString < b.bookID.uuidString }
        return a.chapter == b.chapter ? a.offset < b.offset : a.chapter < b.chapter
    }

    struct Plan: Sendable {
        let books: [Book]
        let corpus: [SourcePassage]
        let ranked: [RetrievalCandidate]
        let query: String
        let selection: SourcePassage?
        let current: SourcePassage?
        let topK: Int
        let chapterOrder: Bool
        let notice: String?
        var rerankPassages: [SourcePassage] {
            let key = selection.map { RetrievalCandidate($0).key }
            return (selection.map { [$0] } ?? []) + ranked.filter { $0.key != key }.map(\.passage)
        }
    }
    static func prepare(query: String, books: [Book], currentBook: UUID?, store: LibraryStore, selection: SourcePassage?, semantic: [RetrievalCandidate], firstChapter: Int, lastChapter: Int, topK: Int, chapterOrder: Bool) throws -> Plan {
        let targets = books.filter { !$0.removed && $0.hasBody && (currentBook == nil || $0.id == currentBook) }
        var corpus: [SourcePassage] = [], characters = 0, chapters = 0, failures = 0, limited = false
        // ponytail: scan canonical chunks per query within 20M characters; persist a lexical index if profiling shows reading delays.
        for book in targets {
            guard book.chapters.indices.contains(book.readThrough.chapter), book.readThrough.offset >= 0, book.readThrough.offset <= book.chapters[book.readThrough.chapter].length else { throw MoReadError.invalid("已读范围无效。") }
            for info in book.chapters where info.id >= firstChapter && info.id <= min(lastChapter, book.readThrough.chapter) {
                try Task.checkCancellation()
                let end = info.id == book.readThrough.chapter ? book.readThrough.offset : info.length
                if end == 0 { continue }
                if chapters == 20000 || end > 20_000_000 - characters { limited = true; break }
                chapters += 1; characters += end
                do { corpus += try BookMemory.chunks(bookID: book.id, chapter: store.chapter(info.id, in: book), scope: ReadingScope(through: book.readThrough)) }
                catch is CancellationError { throw CancellationError() }
                catch { failures += 1 }
            }
            if limited { break }
        }
        func valid(_ passage: SourcePassage) throws -> Bool {
            guard let book = targets.first(where: { $0.id == passage.bookID }), passage.chapter >= firstChapter, passage.chapter <= lastChapter, book.chapters.indices.contains(passage.chapter) else { return false }
            return passage.isValid(in: try store.chapter(passage.chapter, in: book), scope: ReadingScope(through: book.readThrough))
        }
        var vector: [RetrievalCandidate] = []
        for item in semantic {
            try Task.checkCancellation()
            if try valid(item.passage) { vector.append(item) }
        }
        let lexical = try lexical(corpus, query: query), ranked = fuse(vector: vector, lexical: lexical, query: query)
        let selected = try selection.flatMap { try valid($0) ? $0 : nil }
        var current: SourcePassage?
        if let book = targets.first(where: { $0.id == currentBook }), book.chapters.indices.contains(book.position.chapter), book.position.chapter >= firstChapter, book.position.chapter <= lastChapter {
            do {
                let chapter = try store.chapter(book.position.chapter, in: book), text = ReadingScope(through: book.readThrough).readableText(chapter)
                let end = TextBoundary.floor(min(text.utf16.count, book.position.offset + 2000), in: text), start = TextBoundary.floor(max(0, end - 4000), in: text)
                if end > start { current = SourcePassage(bookID: book.id, chapter: chapter, offset: start, text: (text as NSString).substring(with: NSRange(location: start, length: end - start))) }
            } catch is CancellationError { throw CancellationError() }
            catch { current = nil }
        }
        let notice = failures > 0 || limited ? "本次原文扫描未覆盖全部已读内容\(failures > 0 ? "（\(failures) 章读取失败）" : "")\(limited ? "（达到扫描上限）" : "")，没有找到的内容不能据此认定不存在。" : nil
        return Plan(books: targets, corpus: corpus, ranked: ranked, query: query, selection: selected, current: current, topK: topK, chapterOrder: chapterOrder, notice: notice)
    }
    static func finish(_ plan: Plan, order: [SourcePassage]? = nil, store: LibraryStore) throws -> [SourcePassage] {
        var ranked = plan.ranked
        if let order {
            let keys = order.map { RetrievalCandidate($0).key }, originals = Dictionary(uniqueKeysWithValues: ranked.map { ($0.key, $0) })
            let filtered = keys.filter { originals[$0] != nil }
            guard filtered.count == originals.count, Set(filtered) == Set(originals.keys) else { throw MoReadError.invalid("重排结果改变了原文来源。") }
            ranked = filtered.map { originals[$0]! }
        }
        let selected = select(ranked, query: plan.query, topK: plan.topK)
        var windows: [(source: SourcePassage, rank: Int)] = []
        let groups = Dictionary(grouping: plan.corpus) { "\($0.bookID):\($0.chapter)" }
        for (rank, item) in selected.enumerated() {
            try Task.checkCancellation()
            let passage = item.passage, chunks = groups["\(passage.bookID):\(passage.chapter)"] ?? []
            guard let index = chunks.firstIndex(where: { RetrievalCandidate($0).key == item.key }), let book = plan.books.first(where: { $0.id == passage.bookID }) else { windows.append((passage, rank)); continue }
            let first = chunks[max(0, index - 1)], last = chunks[min(chunks.count - 1, index + 1)], end = last.offset + last.text.utf16.count
            let chapter = try store.chapter(passage.chapter, in: book)
            let expanded = SourcePassage(bookID: book.id, chapter: chapter, offset: first.offset, text: (chapter.text as NSString).substring(with: NSRange(location: first.offset, length: end - first.offset)))
            guard expanded.isValid(in: chapter, scope: ReadingScope(through: book.readThrough)) else { throw MoReadError.invalid("检索原文已变化。") }
            windows.append((expanded, rank))
        }
        windows.sort { before($0.source, $1.source) }
        var merged: [(source: SourcePassage, rank: Int)] = []
        for window in windows {
            if let previous = merged.last, previous.source.bookID == window.source.bookID, previous.source.chapter == window.source.chapter,
               window.source.offset <= previous.source.offset + previous.source.text.utf16.count,
               let book = plan.books.first(where: { $0.id == window.source.bookID }) {
                let chapter = try store.chapter(window.source.chapter, in: book)
                let end = max(previous.source.offset + previous.source.text.utf16.count, window.source.offset + window.source.text.utf16.count)
                let source = SourcePassage(bookID: book.id, chapter: chapter, offset: previous.source.offset, text: (chapter.text as NSString).substring(with: NSRange(location: previous.source.offset, length: end - previous.source.offset)))
                merged[merged.count - 1] = (source, min(previous.rank, window.rank))
            } else { merged.append(window) }
        }
        if !plan.chapterOrder { merged.sort { $0.rank < $1.rank } }
        var passages: [SourcePassage] = [], budget = 12000
        for source in (plan.selection.map { [$0] } ?? []) + merged.map(\.source) + (plan.current.map { [$0] } ?? []) {
            guard passages.count < 24, source.text.utf16.count <= budget, !passages.contains(where: { $0.id == source.id }) else { continue }
            passages.append(source); budget -= source.text.utf16.count
        }
        return passages
    }
}
