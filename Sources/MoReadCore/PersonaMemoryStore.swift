import Foundation
import SQLite3
import Accelerate

public final class PersonaMemoryStore {
    private var database: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    public static func url(in root: URL) -> URL { root.appendingPathComponent("companion/persona-memory.sqlite") }
    public init(root: URL) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("companion"), withIntermediateDirectories: true)
        guard sqlite3_open_v2(Self.url(in: root).path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(database); database = nil; throw MoReadError.invalid("无法打开角色记忆。")
        }
        sqlite3_busy_timeout(database, 5000); sqlite3_limit(database, SQLITE_LIMIT_LENGTH, 2 * 1024 * 1024)
        do {
            try execute("PRAGMA journal_mode=DELETE; CREATE TABLE IF NOT EXISTS memories (id TEXT PRIMARY KEY, character TEXT NOT NULL, book TEXT NOT NULL, mask TEXT NOT NULL, fingerprint TEXT NOT NULL, body BLOB NOT NULL, vector BLOB NOT NULL); CREATE INDEX IF NOT EXISTS memory_character ON memories(character,fingerprint); CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY,payload BLOB NOT NULL);")
            if try state(String.self, key: "revision") == nil { try saveState(UUID().uuidString, key: "revision") }
        } catch { sqlite3_close(database); database = nil; throw error }
    }
    deinit { sqlite3_close(database) }
    // ponytail: one revision protects all characters; split revisions per character if concurrent writers become common.
    public var revision: String { get throws { try state(String.self, key: "revision") ?? "" } }
    public func checkpoint(_ conversationID: UUID) throws -> MemoryOrigin? { try state(MemoryOrigin.self, key: "checkpoint-" + conversationID.uuidString) }
    public func profile(_ characterID: UUID) throws -> MemoryProfile { try state(MemoryProfile.self, key: "profile-" + characterID.uuidString) ?? MemoryProfile() }
    public func list(_ characterID: UUID) throws -> [PersonaMemory] {
        try statement("SELECT body FROM memories WHERE character=?", values: [characterID.uuidString]) { sql in
            var values: [PersonaMemory] = []
            while try step(sql) == SQLITE_ROW { values.append(try JSONDecoder().decode(PersonaMemory.self, from: blob(sql, 0))) }
            return values.sorted { $0.updatedAt > $1.updatedAt }
        }
    }
    public func search(characterID: UUID, bookID: UUID?, maskID: UUID?, crossBook: Bool, exactScope: Bool = false, fingerprint: String, vector: [Float], books: [Book], conversations: [Conversation], limit: Int = 8) throws -> [PersonaMemory] {
        let query = try EmbeddingClient.normalized(vector)
        let validOrigins = MemoryOrigin.validated(try list(characterID).flatMap(\.origins), books: books, conversations: conversations)
        var best: [(PersonaMemory, Float)] = []
        // ponytail: native cosine scan per character; use an ANN index if a character exceeds 10,000 memories.
        try statement("SELECT body,vector FROM memories WHERE character=? AND fingerprint=?", values: [characterID.uuidString, fingerprint]) { sql in
            while try step(sql) == SQLITE_ROW {
                try Task.checkCancellation()
                let entry = try JSONDecoder().decode(PersonaMemory.self, from: blob(sql, 0))
                guard !exactScope || (entry.bookID == bookID && entry.maskID == maskID), entry.allowed(bookID: bookID, maskID: maskID, crossBook: crossBook, validOrigins: validOrigins) else { continue }
                let data = try blob(sql, 1)
                guard data.count == query.count * MemoryLayout<Float>.size else { throw MoReadError.invalid("角色记忆的向量维度已变化，请重新整理向量。") }
                var stored = [Float](repeating: 0, count: query.count)
                _ = stored.withUnsafeMutableBytes { data.copyBytes(to: $0) }
                guard stored.allSatisfy(\.isFinite) else { throw MoReadError.invalid("角色记忆向量损坏。") }
                var score: Float = 0; vDSP_dotpr(query, 1, stored, 1, &score, vDSP_Length(query.count))
                if score.isFinite { best.append((entry, score)); best.sort { $0.1 > $1.1 }; if best.count > min(32, max(1, limit)) { best.removeLast() } }
            }
        }
        return best.map(\.0)
    }
    @discardableResult
    public func apply(batch: MemoryBatch, draft: MemoryDraft, vectors: [String: [Float]], fingerprint: String, expectedRevision: String, allowedIDs: Set<UUID>, allowProfile: Bool, profile: MemoryProfile) throws -> Int {
        try transaction {
            guard try revision == expectedRevision else { throw MoReadError.invalid("角色记忆已发生变化，请重新整理。") }
            if let saved = try checkpoint(batch.origin.conversationID), saved.throughMessageID == batch.origin.throughMessageID, saved.fingerprint == batch.origin.fingerprint { return 0 }
            var changed = 0, profileOrigins = profile.origins
            for operation in draft.operations {
                if operation.action == .noop { continue }
                var entry: PersonaMemory
                if operation.action == .add {
                    entry = PersonaMemory(characterID: batch.characterID, bookID: batch.bookID, identity: batch.identity, text: operation.text, origins: [batch.origin])
                } else {
                    guard let id = operation.id, allowedIDs.contains(id), let old = try get(id), old.characterID == batch.characterID, old.bookID == batch.bookID, old.maskID == batch.identity?.maskID else { throw MoReadError.invalid("整理结果引用了其他范围的记忆。") }
                    entry = old; entry.text = operation.text; entry.updatedAt = Date()
                    if !entry.origins.contains(batch.origin) { entry.origins.append(batch.origin) }
                    for origin in old.origins where !profileOrigins.contains(origin) { profileOrigins.append(origin) }
                }
                if operation.action == .delete { try remove(entry.id); try saveState(MemoryProfile(), key: "profile-" + batch.characterID.uuidString) }
                else {
                    guard let vector = vectors[entry.text] else { throw MoReadError.invalid("记忆的向量尚未准备好。") }
                    try put(entry, vector: vector, fingerprint: fingerprint)
                }
                changed += 1
            }
            if allowProfile, batch.identity?.maskID == nil, let text = draft.profile {
                if !profileOrigins.contains(batch.origin) { profileOrigins.append(batch.origin) }
                try saveState(MemoryProfile(text: text, origins: profileOrigins), key: "profile-" + batch.characterID.uuidString)
            }
            try saveState(batch.origin, key: "checkpoint-" + batch.origin.conversationID.uuidString)
            try saveState(UUID().uuidString, key: "revision")
            return changed
        }
    }
    public func forget(_ id: UUID) throws {
        try transaction {
            guard let entry = try get(id) else { return }
            try remove(id); try saveState(MemoryProfile(), key: "profile-" + entry.characterID.uuidString); try saveState(UUID().uuidString, key: "revision")
        }
    }
    public func clear(_ characterID: UUID) throws {
        try transaction {
            try statement("DELETE FROM memories WHERE character=?", values: [characterID.uuidString]) { _ = try step($0) }
            try saveState(MemoryProfile(), key: "profile-" + characterID.uuidString); try saveState(UUID().uuidString, key: "revision")
        }
    }
    public func edit(_ id: UUID, text: String, vector: [Float], fingerprint: String, expectedRevision: String) throws {
        try transaction {
            guard try revision == expectedRevision, var entry = try get(id) else { throw MoReadError.invalid("记忆已变化，请重新打开后编辑。") }
            entry.text = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500)); entry.updatedAt = Date()
            try put(entry, vector: vector, fingerprint: fingerprint)
            try saveState(MemoryProfile(), key: "profile-" + entry.characterID.uuidString); try saveState(UUID().uuidString, key: "revision")
        }
    }
    public func setProfile(_ characterID: UUID, text: String) throws {
        try transaction {
            try saveState(MemoryProfile(text: String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(800))), key: "profile-" + characterID.uuidString)
            try saveState(UUID().uuidString, key: "revision")
        }
    }
    public func reindex(_ entries: [PersonaMemory], vectors: [[Float]], fingerprint: String, expectedRevision: String) throws {
        try transaction {
            guard try revision == expectedRevision, entries.count == vectors.count else { throw MoReadError.invalid("记忆已变化，请重新整理向量。") }
            for (index, entry) in entries.enumerated() {
                guard try get(entry.id) == entry else { throw MoReadError.invalid("记忆已变化，请重新整理向量。") }
                try put(entry, vector: vectors[index], fingerprint: fingerprint)
            }
            try saveState(UUID().uuidString, key: "revision")
        }
    }
    public func validate() throws {
        try statement("PRAGMA quick_check") { sql in
            guard try step(sql) == SQLITE_ROW, let value = sqlite3_column_text(sql, 0), String(cString: value) == "ok" else { throw MoReadError.invalid("备份中的角色记忆损坏。") }
        }
        try statement("SELECT body,vector FROM memories") { sql in
            while try step(sql) == SQLITE_ROW {
                let entry = try JSONDecoder().decode(PersonaMemory.self, from: blob(sql, 0)), vector = try blob(sql, 1)
                guard !entry.text.isEmpty, entry.text.count <= 500, vector.count > 0, vector.count <= 8192 * 4, vector.count % 4 == 0 else { throw MoReadError.invalid("备份中的角色记忆内容无效。") }
                var values = [Float](repeating: 0, count: vector.count / MemoryLayout<Float>.size)
                _ = values.withUnsafeMutableBytes { vector.copyBytes(to: $0) }
                _ = try EmbeddingClient.normalized(values)
            }
        }
        try statement("SELECT key,payload FROM state") { sql in
            while try step(sql) == SQLITE_ROW {
                guard let raw = sqlite3_column_text(sql, 0) else { throw MoReadError.invalid("备份中的记忆状态无效。") }
                let key = String(cString: raw), payload = try blob(sql, 1)
                if key.hasPrefix("profile-") {
                    let profile = try JSONDecoder().decode(MemoryProfile.self, from: payload)
                    guard profile.text.count <= 800 else { throw MoReadError.invalid("备份中的用户画像过长。") }
                } else if key.hasPrefix("checkpoint-") { _ = try JSONDecoder().decode(MemoryOrigin.self, from: payload) }
                else if key == "revision" { _ = try JSONDecoder().decode(String.self, from: payload) }
            }
        }
    }
    private func get(_ id: UUID) throws -> PersonaMemory? {
        try statement("SELECT body FROM memories WHERE id=?", values: [id.uuidString]) { sql in try step(sql) == SQLITE_ROW ? JSONDecoder().decode(PersonaMemory.self, from: blob(sql, 0)) : nil }
    }
    private func put(_ entry: PersonaMemory, vector: [Float], fingerprint: String) throws {
        guard !entry.text.isEmpty, entry.text.count <= 500 else { throw MoReadError.invalid("记忆内容应为 1 至 500 字。") }
        let vector = try EmbeddingClient.normalized(vector), body = try JSONEncoder().encode(entry)
        try statement("INSERT OR REPLACE INTO memories(id,character,book,mask,fingerprint,body,vector) VALUES(?,?,?,?,?,?,?)", values: [entry.id.uuidString, entry.characterID.uuidString, entry.bookID?.uuidString ?? "", entry.maskID?.uuidString ?? "", fingerprint]) { sql in
            bind(body, index: 6, sql: sql); vector.withUnsafeBytes { bind(Data($0), index: 7, sql: sql) }; _ = try step(sql)
        }
    }
    private func remove(_ id: UUID) throws { try statement("DELETE FROM memories WHERE id=?", values: [id.uuidString]) { _ = try step($0) } }
    private func state<T: Decodable>(_ type: T.Type, key: String) throws -> T? {
        try statement("SELECT payload FROM state WHERE key=?", values: [key]) { sql in try step(sql) == SQLITE_ROW ? JSONDecoder().decode(type, from: blob(sql, 0)) : nil }
    }
    private func saveState<T: Encodable>(_ value: T, key: String) throws {
        let data = try JSONEncoder().encode(value)
        try statement("INSERT OR REPLACE INTO state(key,payload) VALUES(?,?)", values: [key]) { sql in bind(data, index: 2, sql: sql); _ = try step(sql) }
    }
    private func bind(_ data: Data, index: Int32, sql: OpaquePointer) { _ = data.withUnsafeBytes { sqlite3_bind_blob(sql, index, $0.baseAddress, Int32($0.count), transient) } }
    private func blob(_ sql: OpaquePointer, _ column: Int32) throws -> Data {
        let size = Int(sqlite3_column_bytes(sql, column))
        guard size > 0, size <= 2 * 1024 * 1024, let value = sqlite3_column_blob(sql, column) else { throw MoReadError.invalid("角色记忆数据不完整。") }
        return Data(bytes: value, count: size)
    }
    private func statement<T>(_ command: String, values: [String] = [], _ body: (OpaquePointer) throws -> T) throws -> T {
        var sql: OpaquePointer?
        guard sqlite3_prepare_v2(database, command, -1, &sql, nil) == SQLITE_OK, let sql else { throw MoReadError.invalid("角色记忆格式无效。") }
        defer { sqlite3_finalize(sql) }
        for (index, value) in values.enumerated() { _ = value.withCString { sqlite3_bind_text(sql, Int32(index + 1), $0, Int32(value.utf8.count), transient) } }
        return try body(sql)
    }
    private func step(_ sql: OpaquePointer) throws -> Int32 {
        let result = sqlite3_step(sql)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw MoReadError.invalid("角色记忆未能保存，请检查可用空间。") }; return result
    }
    private func execute(_ command: String) throws { guard sqlite3_exec(database, command, nil, nil, nil) == SQLITE_OK else { throw MoReadError.invalid("无法更新角色记忆。") } }
    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let value = try body(); try execute("COMMIT"); return value } catch { try? execute("ROLLBACK"); throw error }
    }
}
