import Foundation
import SQLite3
import Accelerate

public enum BookMemory {
    public typealias Embed = @Sendable ([String]) async throws -> [[Float]]
    public static func chunks(bookID: UUID, chapter: Chapter, scope: ReadingScope) -> [SourcePassage] {
        let text = scope.readableText(chapter)
        var result: [SourcePassage] = [], start: Int?, end = 0, cursor = 0
        func append() {
            if let start, end > start {
                result.append(SourcePassage(bookID: bookID, chapter: chapter, offset: start, text: (text as NSString).substring(with: NSRange(location: start, length: end - start))))
            }
        }
        while let segment = SpeechText.next(in: text, from: cursor, maximumLength: 640) {
            if let current = start, segment.end - current > 640 || end - current >= 480 { append(); start = nil }
            if start == nil { start = segment.offset }
            end = segment.end; cursor = end
        }
        append(); return result
    }
    public static func index(book: Book, root: URL, fingerprint: String, embed: Embed, progress: @Sendable (Int, Int) async -> Void = { _, _ in }) async throws {
        guard !book.removed, book.hasBody else { throw MoReadError.invalid("正文已移除，无法建立向量记忆。") }
        let library = try LibraryStore(root: root)
        let index = try BookVectorIndex(url: library.directory(book.id).appendingPathComponent("vectors.sqlite"), fingerprint: fingerprint)
        let scope = ReadingScope(through: book.readThrough)
        let readable = book.chapters.filter { $0.id < scope.end.chapter || ($0.id == scope.end.chapter && scope.end.offset > 0) }
        var done = 0
        await progress(done, readable.count)
        for info in readable {
            try Task.checkCancellation()
            let end = info.id < scope.end.chapter ? info.length : min(info.length, scope.end.offset)
            func validate() throws {
                let current = try library.book(book.id)
                guard current.hasBody, !current.removed, current.readThrough >= ReadingPosition(chapter: info.id, offset: end),
                      current.chapters.indices.contains(info.id), current.chapters[info.id].revision == info.revision else { throw MoReadError.invalid("书籍或已读范围发生变化，请重新建立向量记忆。") }
            }
            try validate()
            if try !index.contains(info, through: end) {
                let chapter = try library.chapter(info.id, in: book)
                let passages = chunks(bookID: book.id, chapter: chapter, scope: ReadingScope(through: .init(chapter: info.id, offset: end)))
                var vectors: [[Float]] = []
                for start in stride(from: 0, to: passages.count, by: 32) {
                    try Task.checkCancellation(); try validate()
                    let batch = Array(passages[start..<min(start + 32, passages.count)])
                    let encoded = try await embed(batch.map { String(info.title.prefix(200)) + "\n" + $0.text })
                    guard encoded.count == batch.count else { throw MoReadError.invalid("返回的向量数量与原文不一致。") }
                    vectors += try encoded.map(EmbeddingClient.normalized)
                }
                try Task.checkCancellation(); try validate()
                try index.replace(info, through: end, passages: passages, vectors: vectors)
            }
            done += 1; await progress(done, readable.count)
        }
    }
    public static func retrieve(query: String, books: [Book], root: URL, fingerprint: String, embed: Embed, progress: @Sendable (String, Int, Int) async -> Void = { _, _, _ in }) async throws -> [SourcePassage] {
        let books = books.filter { !$0.removed && $0.hasBody && $0.readThrough > ReadingPosition() }
        guard !books.isEmpty else { return [] }
        for book in books {
            try await index(book: book, root: root, fingerprint: fingerprint, embed: embed) { done, total in await progress(book.title, done, total) }
        }
        try Task.checkCancellation()
        let vectors = try await embed([TextBoundary.prefix(query, end: 2000)])
        guard vectors.count == 1 else { throw MoReadError.invalid("问题的向量数量无效。") }
        try Task.checkCancellation()
        return try books.flatMap { try search(book: $0, root: root, fingerprint: fingerprint, vector: vectors[0], limit: 8) }
    }
    public static func search(book: Book, root: URL, fingerprint: String, vector: [Float], limit: Int = 12) throws -> [SourcePassage] {
        guard !book.removed, book.hasBody, limit > 0 else { return [] }
        let library = try LibraryStore(root: root)
        let url = library.directory(book.id).appendingPathComponent("vectors.sqlite")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try BookVectorIndex(url: url, fingerprint: fingerprint).search(book: book, library: library, vector: vector, limit: min(limit, 32))
    }
}

/// Connections use SQLite's full mutex mode and a single-file rollback journal.
public final class BookVectorIndex {
    private var database: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    public init(url: URL, fingerprint: String? = nil) throws {
        let flags = fingerprint == nil ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(url.path, &database, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(database); database = nil; throw MoReadError.invalid("无法打开向量记忆。")
        }
        sqlite3_busy_timeout(database, 5000)
        sqlite3_limit(database, SQLITE_LIMIT_LENGTH, 512 * 1024)
        do {
            guard let fingerprint else { return }
            try execute("PRAGMA journal_mode=DELETE; CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL); CREATE TABLE IF NOT EXISTS chapters (chapter INTEGER PRIMARY KEY, revision TEXT NOT NULL, read_end INTEGER NOT NULL); CREATE TABLE IF NOT EXISTS chunks (chapter INTEGER NOT NULL, offset INTEGER NOT NULL, end_offset INTEGER NOT NULL, text TEXT NOT NULL, vector BLOB NOT NULL, PRIMARY KEY(chapter, offset));")
            let previous = try metadata("fingerprint")
            if previous != fingerprint {
                try transaction {
                    try execute("DELETE FROM chunks; DELETE FROM chapters; DELETE FROM meta;")
                    try setMetadata("fingerprint", fingerprint)
                }
            }
        } catch { sqlite3_close(database); database = nil; throw error }
    }
    deinit { sqlite3_close(database) }
    public func contains(_ info: ChapterInfo, through end: Int) throws -> Bool {
        try statement("SELECT revision, read_end FROM chapters WHERE chapter=?") { sql in
            sqlite3_bind_int64(sql, 1, Int64(info.id))
            return try step(sql) == SQLITE_ROW && text(sql, 0) == info.revision && sqlite3_column_int64(sql, 1) == Int64(end)
        }
    }
    public func replace(_ info: ChapterInfo, through end: Int, passages: [SourcePassage], vectors: [[Float]]) throws {
        guard info.id >= 0, end >= 0, end <= info.length, passages.count == vectors.count else { throw MoReadError.invalid("向量记忆不完整。") }
        let vectors = try vectors.map(EmbeddingClient.normalized)
        let dimension = vectors.first?.count
        if let dimension, let old = try metadata("dimensions"), old != String(dimension) { throw MoReadError.invalid("向量维度已变化，请清理这本书的向量记忆后重建。") }
        guard dimension == nil || vectors.allSatisfy({ $0.count == dimension && !$0.isEmpty && $0.count <= 8192 && $0.allSatisfy(\.isFinite) }),
              passages.allSatisfy({ $0.chapter == info.id && $0.revision == info.revision && $0.offset >= 0 && !$0.text.isEmpty && $0.text.utf16.count <= 640 && $0.offset <= end - $0.text.utf16.count }) else { throw MoReadError.invalid("向量记忆的原文范围无效。") }
        try transaction {
            try statement("DELETE FROM chunks WHERE chapter=?") { sql in sqlite3_bind_int64(sql, 1, Int64(info.id)); _ = try step(sql) }
            try statement("INSERT INTO chunks(chapter,offset,end_offset,text,vector) VALUES(?,?,?,?,?)") { sql in
                for (index, passage) in passages.enumerated() {
                    sqlite3_reset(sql); sqlite3_clear_bindings(sql)
                    sqlite3_bind_int64(sql, 1, Int64(info.id)); sqlite3_bind_int64(sql, 2, Int64(passage.offset)); sqlite3_bind_int64(sql, 3, Int64(passage.offset + passage.text.utf16.count))
                    bind(passage.text, at: 4, to: sql)
                    _ = vectors[index].withUnsafeBytes { sqlite3_bind_blob(sql, 5, $0.baseAddress, Int32($0.count), transient) }
                    _ = try step(sql)
                }
            }
            try statement("INSERT OR REPLACE INTO chapters(chapter,revision,read_end) VALUES(?,?,?)") { sql in
                sqlite3_bind_int64(sql, 1, Int64(info.id)); bind(info.revision, at: 2, to: sql); sqlite3_bind_int64(sql, 3, Int64(end)); _ = try step(sql)
            }
            if let dimension { try setMetadata("dimensions", String(dimension)) }
        }
    }
    public func count() throws -> Int { try statement("SELECT COUNT(*) FROM chunks") { sql in _ = try step(sql); return Int(sqlite3_column_int64(sql, 0)) } }
    public func search(book: Book, library: LibraryStore, vector: [Float], limit: Int) throws -> [SourcePassage] {
        guard limit > 0, !book.removed, book.hasBody else { return [] }
        let limit = min(limit, 32)
        let query = try EmbeddingClient.normalized(vector)
        if let dimension = try metadata("dimensions"), dimension != String(query.count) { throw MoReadError.invalid("问题与原文的向量维度不同，请重建向量记忆。") }
        struct Match { let chapter: Int; let offset: Int; let text: String; let score: Float }
        var best: [Match] = []
        // ponytail: scan vectors with native SIMD; use an ANN index when individual books exceed 50,000 chunks.
        try statement("SELECT c.chapter,c.offset,c.end_offset,c.text,c.vector,h.revision FROM chunks c JOIN chapters h ON h.chapter=c.chapter WHERE c.chapter<? OR (c.chapter=? AND c.end_offset<=?)") { sql in
            sqlite3_bind_int64(sql, 1, Int64(book.readThrough.chapter)); sqlite3_bind_int64(sql, 2, Int64(book.readThrough.chapter)); sqlite3_bind_int64(sql, 3, Int64(book.readThrough.offset))
            while try step(sql) == SQLITE_ROW {
                try Task.checkCancellation()
                let chapter = Int(sqlite3_column_int64(sql, 0)), offset = Int(sqlite3_column_int64(sql, 1)), end = Int(sqlite3_column_int64(sql, 2))
                guard book.chapters.indices.contains(chapter), text(sql, 5) == book.chapters[chapter].revision, offset >= 0, end >= offset, end - offset <= 640 else { continue }
                let content = text(sql, 3)
                guard content.utf16.count == end - offset, sqlite3_column_bytes(sql, 4) == query.count * MemoryLayout<Float>.size, let blob = sqlite3_column_blob(sql, 4) else { throw MoReadError.invalid("向量记忆损坏，请清理后重建。") }
                var values = [Float](repeating: 0, count: query.count)
                _ = values.withUnsafeMutableBytes { memcpy($0.baseAddress!, blob, $0.count) }
                guard values.allSatisfy(\.isFinite) else { throw MoReadError.invalid("向量记忆包含无效数字。") }
                var score: Float = 0
                vDSP_dotpr(query, 1, values, 1, &score, vDSP_Length(query.count))
                guard score.isFinite else { continue }
                best.append(Match(chapter: chapter, offset: offset, text: content, score: score))
                best.sort { $0.score > $1.score }; if best.count > limit { best.removeLast() }
            }
        }
        var result: [SourcePassage] = []
        for match in best {
            let chapter = try library.chapter(match.chapter, in: book)
            let passage = SourcePassage(bookID: book.id, chapter: chapter, offset: match.offset, text: match.text)
            if passage.isValid(in: chapter, scope: ReadingScope(through: book.readThrough)) { result.append(passage) }
        }
        return result
    }
    private func metadata(_ key: String) throws -> String? {
        try statement("SELECT value FROM meta WHERE key=?") { sql in bind(key, at: 1, to: sql); return try step(sql) == SQLITE_ROW ? text(sql, 0) : nil }
    }
    private func setMetadata(_ key: String, _ value: String) throws {
        try statement("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)") { sql in bind(key, at: 1, to: sql); bind(value, at: 2, to: sql); _ = try step(sql) }
    }
    private func bind(_ value: String, at index: Int32, to sql: OpaquePointer) {
        _ = value.withCString { sqlite3_bind_text(sql, index, $0, Int32(value.utf8.count), transient) }
    }
    private func text(_ sql: OpaquePointer, _ column: Int32) -> String {
        guard let bytes = sqlite3_column_text(sql, column) else { return "" }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(sql, column))), as: UTF8.self)
    }
    private func step(_ sql: OpaquePointer) throws -> Int32 {
        let status = sqlite3_step(sql)
        guard status == SQLITE_ROW || status == SQLITE_DONE else { throw MoReadError.invalid("无法读写向量记忆，请检查可用空间。") }
        return status
    }
    private func statement<T>(_ command: String, _ action: (OpaquePointer) throws -> T) throws -> T {
        var sql: OpaquePointer?
        guard sqlite3_prepare_v2(database, command, -1, &sql, nil) == SQLITE_OK, let sql else { throw MoReadError.invalid("向量记忆格式无效。") }
        defer { sqlite3_finalize(sql) }
        return try action(sql)
    }
    private func execute(_ command: String) throws {
        guard sqlite3_exec(database, command, nil, nil, nil) == SQLITE_OK else { throw MoReadError.invalid("无法更新向量记忆，请检查可用空间。") }
    }
    private func transaction(_ action: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try action(); try execute("COMMIT") } catch { try? execute("ROLLBACK"); throw error }
    }
}
