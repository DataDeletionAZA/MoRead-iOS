import XCTest
import SQLite3
@testable import MoReadCore

final class PersonaMemoryTests: XCTestCase {
    private func conversation(_ count: Int = 30, character: UUID = UUID(), book: UUID? = nil, identity: ChatIdentity? = nil) -> Conversation {
        var value = Conversation(title: "共读", bookID: book, characterID: character)
        value.messages = (0..<count).map { index in
            var message = ChatMessage(role: index.isMultiple(of: 2) ? "user" : "assistant", content: "第\(index)条：我喜欢安静的书店。")
            message.identity = identity; return message
        }
        return value
    }
    func testBatchIdentityBoundariesWatermarksAndParsers() throws {
        XCTAssertNil(try MemoryBatch.plan(conversation(29), checkpoint: nil, onClose: false))
        XCTAssertNil(try MemoryBatch.plan(conversation(9), checkpoint: nil, onClose: true))
        XCTAssertNotNil(try MemoryBatch.plan(conversation(10), checkpoint: nil, onClose: true))
        var chat = conversation(50)
        let mask = ChatIdentity(name: "读者", mask: UserMask(name: "旅行者"))
        for index in 8..<50 { chat.messages[index].identity = mask }
        let first = try XCTUnwrap(MemoryBatch.plan(chat, checkpoint: nil, onClose: false))
        XCTAssertEqual(first.origin.throughMessageID, chat.messages[7].id)
        XCTAssertNil(first.identity); XCTAssertFalse(first.transcript.contains("第8条"))
        let next = try XCTUnwrap(MemoryBatch.plan(chat, checkpoint: first.origin, onClose: false))
        XCTAssertEqual(next.identity?.maskID, mask.maskID)
        XCTAssertTrue(next.transcript.contains("第8条")); XCTAssertFalse(next.transcript.contains("第7条"))
        chat.messages[0].content = "已经改写"
        XCTAssertFalse(first.origin.matches(chat))
        XCTAssertTrue(try XCTUnwrap(MemoryBatch.plan(chat, checkpoint: first.origin, onClose: false)).transcript.contains("已经改写"))
        for index in chat.messages.indices { chat.messages[index].content = "第\(index)条" + String(repeating: "长", count: 3000); chat.messages[index].identity = nil }
        let bounded = try XCTUnwrap(MemoryBatch.plan(chat, checkpoint: nil, onClose: false))
        let end = try XCTUnwrap(chat.messages.firstIndex { $0.id == bounded.origin.throughMessageID })
        XCTAssertLessThanOrEqual(bounded.transcript.utf16.count, 30000); XCTAssertLessThan(end, 29)
        XCTAssertTrue(bounded.transcript.contains("第\(end)条")); XCTAssertFalse(bounded.transcript.contains("第\(end + 1)条"))
        XCTAssertEqual(try MemoryDraft.candidates("```json\n[\"书店\",\"书店\",\" \" ]\n```"), ["书店"])
        XCTAssertEqual(try MemoryDraft.parse("{\"operations\":[{\"action\":\"NOOP\"}],\"user_profile\":null}").operations.first?.action, .noop)
        XCTAssertThrowsError(try MemoryDraft.parse("{\"operations\":[{\"action\":\"DELETE\"}]}"))
        XCTAssertThrowsError(try MemoryDraft.candidates(String(repeating: "x", count: 65537)))
    }
    func testAtomicUpdatesIsolationDeduplicationAndForgetting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PersonaMemoryStore(root: root), character = UUID(), book = UUID()
        let chat = conversation(character: character, book: book)
        let batch = try XCTUnwrap(MemoryBatch.plan(chat, checkpoint: nil, onClose: false))
        let draft = try MemoryDraft.parse("{\"operations\":[{\"action\":\"ADD\",\"summary\":\"喜欢书店\"}],\"user_profile\":\"喜欢阅读\"}")
        let changed = try store.apply(batch: batch, draft: draft, vectors: ["喜欢书店": [1,0]], fingerprint: "model", expectedRevision: store.revision, allowedIDs: [], allowProfile: false, profile: MemoryProfile())
        XCTAssertEqual(changed, 1); XCTAssertEqual(try store.profile(character).text, "")
        XCTAssertEqual(try store.apply(batch: batch, draft: draft, vectors: ["喜欢书店": [1,0]], fingerprint: "model", expectedRevision: store.revision, allowedIDs: [], allowProfile: false, profile: MemoryProfile()), 0)
        let entry = try XCTUnwrap(store.list(character).first)
        XCTAssertEqual(try store.search(characterID: character, bookID: book, maskID: nil, crossBook: false, fingerprint: "model", vector: [1,0], books: [], conversations: [chat]).count, 1)
        XCTAssertTrue(try store.search(characterID: character, bookID: UUID(), maskID: nil, crossBook: false, fingerprint: "model", vector: [1,0], books: [], conversations: [chat]).isEmpty)
        XCTAssertTrue(try store.search(characterID: UUID(), bookID: nil, maskID: nil, crossBook: true, fingerprint: "model", vector: [1,0], books: [], conversations: [chat]).isEmpty)
        var edited = chat; edited.messages[0].content = "相反的偏好"
        XCTAssertTrue(try store.search(characterID: character, bookID: nil, maskID: nil, crossBook: true, fingerprint: "model", vector: [1,0], books: [], conversations: [edited]).isEmpty)
        let other = conversation(character: character, book: UUID()), otherBatch = try XCTUnwrap(MemoryBatch.plan(other, checkpoint: nil, onClose: false))
        let bad = try MemoryDraft.parse("{\"operations\":[{\"action\":\"ADD\",\"summary\":\"不应留下\"},{\"action\":\"DELETE\",\"id\":\"\(entry.id)\"}]}")
        XCTAssertThrowsError(try store.apply(batch: otherBatch, draft: bad, vectors: ["不应留下": [1,0]], fingerprint: "model", expectedRevision: store.revision, allowedIDs: [entry.id], allowProfile: false, profile: MemoryProfile()))
        XCTAssertEqual(try store.list(character).count, 1); XCTAssertNil(try store.checkpoint(other.id))
        let global = conversation(character: character), globalBatch = try XCTUnwrap(MemoryBatch.plan(global, checkpoint: nil, onClose: false))
        _ = try store.apply(batch: globalBatch, draft: draft, vectors: ["喜欢书店": [1,0]], fingerprint: "model", expectedRevision: store.revision, allowedIDs: [], allowProfile: true, profile: MemoryProfile())
        XCTAssertEqual(try store.profile(character).text, "喜欢阅读")
        try store.forget(entry.id)
        XCTAssertEqual(try store.profile(character).text, ""); XCTAssertEqual(try store.list(character).count, 1)
        XCTAssertNotNil(try store.checkpoint(chat.id))
        try PersonaMemoryStore(root: root).validate()
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(PersonaMemoryStore.url(in: root).path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "UPDATE memories SET vector=zeroblob(8)", nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try store.validate())
        try store.clear(character); XCTAssertTrue(try PersonaMemoryStore(root: root).list(character).isEmpty)
    }
    func testPrefixFingerprintsAndRecordedReadingScopes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var book = try LibraryStore(root: root).importBook(title: "书店", chapters: [.init(id: 0, title: "第一章", text: "橱窗旁边是一排书架，门外还在下雨。")])
        book.readThrough = .init(chapter: 0, offset: 5)
        var chat = conversation()
        chat.sourceLimits = [book.id: book.readThrough]; chat.sourceRevisions = [book.id: book.chapters.map(\.revision)]
        chat.messages[9].bookScopes = try MemoryBookScope.snapshot(chat)
        chat.sourceLimits[book.id] = .init(chapter: 0, offset: 15)
        chat.messages[29].bookScopes = try MemoryBookScope.snapshot(chat)
        let ids = Set([chat.messages[9].id, chat.messages[19].id, chat.messages[29].id])
        let hashes = RollingSummary.fingerprints(chat.messages, through: ids)
        for id in ids { XCTAssertEqual(hashes[id], RollingSummary.fingerprint(chat.messages, through: id)) }
        let origins = try [9,19,29].map { try MemoryOrigin(conversation: chat, through: chat.messages[$0].id) }
        XCTAssertEqual(origins[0].books.first?.through.offset, 5)
        XCTAssertEqual(origins[1].books.first?.through.offset, 5)
        XCTAssertEqual(origins[2].books.first?.through.offset, 15)
        XCTAssertEqual(MemoryOrigin.validated(origins, books: [book], conversations: [chat]), Set(origins.prefix(2)))
        book.readThrough = .init(chapter: 0, offset: 15)
        chat.messages[15].content = "更正原来的说法"
        let valid = MemoryOrigin.validated(origins, books: [book], conversations: [chat])
        XCTAssertEqual(valid, Set(origins.prefix(1)))
        for origin in origins { XCTAssertEqual(valid.contains(origin), origin.isValid(books: [book], conversations: [chat])) }
    }
    func testUpdateAndNoopKeepOneMemoryAndAdvanceCheckpoint() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PersonaMemoryStore(root: root)
        var chat = conversation()
        let first = try XCTUnwrap(MemoryBatch.plan(chat, checkpoint: nil, onClose: false))
        _ = try store.apply(batch: first, draft: MemoryDraft.parse("[{\"action\":\"ADD\",\"summary\":\"书店\"}]"), vectors: ["书店": [1,0]], fingerprint: "model", expectedRevision: store.revision, allowedIDs: [], allowProfile: false, profile: MemoryProfile())
        let entry = try XCTUnwrap(store.list(chat.characterID).first)
        chat.messages += conversation().messages
        let second = try XCTUnwrap(MemoryBatch.plan(chat, checkpoint: first.origin, onClose: false))
        let update = try MemoryDraft.parse("[{\"action\":\"UPDATE\",\"id\":\"\(entry.id)\",\"summary\":\"安静的书店\"}]")
        XCTAssertEqual(try store.apply(batch: second, draft: update, vectors: ["安静的书店": [1,0]], fingerprint: "model", expectedRevision: store.revision, allowedIDs: [entry.id], allowProfile: false, profile: MemoryProfile()), 1)
        let updated = try XCTUnwrap(store.list(chat.characterID).first)
        XCTAssertEqual(updated.id, entry.id); XCTAssertEqual(updated.text, "安静的书店")
        XCTAssertEqual(updated.origins, [first.origin, second.origin])
        chat.messages += conversation().messages
        let third = try XCTUnwrap(MemoryBatch.plan(chat, checkpoint: second.origin, onClose: false))
        XCTAssertEqual(try store.apply(batch: third, draft: MemoryDraft.parse("[{\"action\":\"NOOP\"}]"), vectors: [:], fingerprint: "model", expectedRevision: store.revision, allowedIDs: [entry.id], allowProfile: false, profile: MemoryProfile()), 0)
        XCTAssertEqual(try store.list(chat.characterID), [updated])
        XCTAssertEqual(try store.checkpoint(chat.id), third.origin)
    }
    func testMaskScopeSpoilerBoundaryAndVectorRebuild() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try LibraryStore(root: root)
        var book = try library.importBook(title: "书店", chapters: [.init(id: 0, title: "第一章", text: "看见橱窗与书架，雨还没有停。")])
        book.readThrough = .init(chapter: 0, offset: 8)
        let identity = ChatIdentity(name: "读者", mask: UserMask(name: "旅行者")), character = UUID()
        var chat = conversation(character: character, book: book.id, identity: identity)
        chat.sourceLimits = [book.id: book.readThrough]; chat.sourceRevisions = [book.id: book.chapters.map(\.revision)]
        let store = try PersonaMemoryStore(root: root), batch = try XCTUnwrap(MemoryBatch.plan(chat, checkpoint: nil, onClose: false))
        let draft = try MemoryDraft.parse("{\"operations\":[{\"action\":\"ADD\",\"summary\":\"旅行者看见橱窗\"}],\"user_profile\":\"不能写成本人\"}")
        _ = try store.apply(batch: batch, draft: draft, vectors: ["旅行者看见橱窗": [1,0]], fingerprint: "old", expectedRevision: store.revision, allowedIDs: [], allowProfile: true, profile: MemoryProfile())
        XCTAssertTrue(try store.profile(character).text.isEmpty)
        func search(_ mask: UUID?, _ books: [Book]) throws -> [PersonaMemory] { try store.search(characterID: character, bookID: book.id, maskID: mask, crossBook: false, fingerprint: "old", vector: [1,0], books: books, conversations: [chat]) }
        XCTAssertEqual(try search(identity.maskID, [book]).count, 1)
        XCTAssertTrue(try search(nil, [book]).isEmpty); XCTAssertTrue(try search(UUID(), [book]).isEmpty)
        var earlier = book; earlier.readThrough = .init(chapter: 0, offset: 2)
        XCTAssertTrue(try search(identity.maskID, [earlier]).isEmpty)
        let entries = try store.list(character), oldRevision = try store.revision
        try store.reindex(entries, vectors: [[0,1,0]], fingerprint: "new", expectedRevision: oldRevision)
        XCTAssertThrowsError(try store.reindex(entries, vectors: [[1,0]], fingerprint: "old", expectedRevision: oldRevision))
        XCTAssertEqual(try store.search(characterID: character, bookID: book.id, maskID: identity.maskID, crossBook: false, fingerprint: "new", vector: [0,1,0], books: [book], conversations: [chat]).count, 1)
        XCTAssertTrue(try search(identity.maskID, [book]).isEmpty)
        let archive = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".zip")
        defer { try? FileManager.default.removeItem(at: archive) }
        _ = try await BackupArchive.create(root: root, output: archive)
        let restored = try await BackupArchive.prepare(archive, beside: root)
        defer { try? FileManager.default.removeItem(at: restored.directory) }
        XCTAssertEqual(try PersonaMemoryStore(root: restored.directory).list(character).first?.text, "旅行者看见橱窗")
    }
}
