import XCTest
@testable import MoReadCore

@MainActor final class BookCharactersTests: XCTestCase {
    private let model = ChapterKnowledgeEntry.hash("characters-test-model")
    private actor Replies {
        var sources: [String] = []
        let failure: String?
        let slow: Bool
        init(failure: String? = nil, slow: Bool = false) { self.failure = failure; self.slow = slow }
        func reply(_ messages: [ChatMessage], tool: ChatTool) async throws -> ChatToolRound {
            let source = messages.last!.content.components(separatedBy: "<source>\n").last!.components(separatedBy: "\n</source>").first!
            sources.append(source)
            if slow { try await Task.sleep(nanoseconds: 5_000_000_000) }
            if let failure, source.contains(failure) { throw MoReadError.invalid("模拟提取失败") }
            let characters: [[String: Any]] = ["阿翎", "小岚"].filter { source.contains($0) }.map {
                ["name": $0, "facts": [["text": source, "quote": source]]]
            }
            let raw = String(decoding: try JSONSerialization.data(withJSONObject: ["characters": characters]), as: UTF8.self)
            return .init(text: "", calls: [.init(id: UUID().uuidString, name: tool.name, arguments: raw)], replay: Data("{}".utf8))
        }
    }
    private func generate(_ store: BookCharactersStore, plan: BookCharactersPlan, replies: Replies) async throws -> BookCharacterGuide {
        try await store.generate(plan, stream: { messages, tool, _ in try await replies.reply(messages, tool: tool) }, validate: {})
    }
    func testCharacterParsingLongSourcesAndBoundedEvidenceRetention() throws {
        let long = String(repeating: "字", count: 70_000)
        XCTAssertThrowsError(try KnowledgePart.split(long))
        XCTAssertEqual(try KnowledgePart.split(long, enforceChapterLimit: false).map(\.text).joined(), long)
        let part = KnowledgePart(start: 70_000, text: "🌙阿翎来到灯塔。")
        let raw = #"{"characters":[{"name":"阿翎","facts":[{"text":"来到灯塔","quote":"阿翎来到灯塔。","start":999}]}]}"#
        let people = try ChapterKnowledge.parseCharacters(raw, part: part)
        XCTAssertEqual(people[0].facts[0].start, 70_002)
        try ChapterKnowledge.validateCharacters(people, part: part)
        XCTAssertThrowsError(try ChapterKnowledge.validateCharacters(people, part: .init(start: 70_001, text: part.text)))
        XCTAssertEqual(try ChapterKnowledge.parseCharacters(#"{"characters":[]}"#, part: part), [])
        XCTAssertThrowsError(try ChapterKnowledge.parseCharacters(raw.replacingOccurrences(of: "\"name\":\"阿翎\"", with: "\"name\":\"她\""), part: part))
        XCTAssertThrowsError(try ChapterKnowledge.parseCharacters(raw, part: .init(start: Int.max, text: part.text)))
        XCTAssertThrowsError(try ChapterKnowledge.parseCharacters(raw, part: .init(start: 0, text: "阿翎来到灯塔。阿翎来到灯塔。")))
        var accumulator = BookCharacterAccumulator()
        for index in 0..<24 {
            let fact = KnowledgeFact(text: "事实\(index)", quote: "原文依据", start: 0, end: 4)
            accumulator.add(chapter: index, characters: [.init(name: "阿翎", facts: [fact])])
        }
        accumulator.add(chapter: 25, characters: [.init(name: "阿翎", facts: [.init(text: "事实23", quote: "原文依据", start: 0, end: 4)]), .init(name: "小翎", facts: people[0].facts)])
        XCTAssertEqual(accumulator.characters.map(\.name), ["阿翎", "小翎"])
        XCTAssertEqual(accumulator.characters[0].evidence.map(\.chapter), [0, 1, 2, 3] + Array(12..<24))
    }
    func testReadScopeUpdatesReusePartsFullBookConsentPlanAndDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try LibraryStore(root: root)
        let chapters = [Chapter(id: 0, title: "一", text: "阿翎来到灯塔。"), Chapter(id: 1, title: "二", text: "小岚坐在窗边。"), Chapter(id: 2, title: "三", text: "阿翎打开来信。")]
        var book = try library.importBook(title: "灯塔", chapters: chapters)
        let store = BookCharactersStore(library: library, bookID: book.id)
        XCTAssertThrowsError(try store.preview(modelFingerprint: model, modelLabel: "本地"))
        book.readThrough = .init(offset: 7); try library.save(book)
        let originalSize = try library.storageBytes(for: book)
        let plan = try store.preview(modelFingerprint: model, modelLabel: "本地")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
        XCTAssertTrue(plan.progressBounded); XCTAssertEqual(plan.chapters.count, 1); XCTAssertEqual(plan.sourceCharacters, 7); XCTAssertEqual(plan.maximumRequests, 2)
        let replies = Replies()
        let initial = try await generate(store, plan: plan, replies: replies)
        XCTAssertEqual(initial.characters.map(\.name), ["阿翎"])
        let firstSources = await replies.sources; XCTAssertEqual(firstSources, [chapters[0].text])
        let reused = try await generate(store, plan: store.preview(modelFingerprint: model, modelLabel: "本地"), replies: replies)
        let secondSources = await replies.sources; XCTAssertEqual(secondSources.count, 1)
        XCTAssertNotEqual(initial.generationID, reused.generationID); XCTAssertNil(try store.checkpoint())
        book.readThrough = .init(chapter: 1, offset: 4); try library.save(book)
        let updated = try await generate(store, plan: store.preview(modelFingerprint: model, modelLabel: "本地"), replies: replies)
        let updatedSources = await replies.sources; XCTAssertEqual(updatedSources, [chapters[0].text, "小岚坐在"])
        XCTAssertEqual(updated.sourceCharacters, 11); XCTAssertEqual(updated.characters.count, 2)
        let evidence = updated.characters[1].evidence[0]
        XCTAssertEqual(try store.locate(updated, evidence: evidence).chapter, 1)
        let pending = try store.preview(modelFingerprint: model, modelLabel: "本地")
        book.readThrough = .init(offset: 7); try library.save(book)
        XCTAssertThrowsError(try store.validatePlan(pending))
        XCTAssertFalse(updated.visible(in: book)); XCTAssertThrowsError(try store.locate(updated, evidence: evidence))
        let whole = try store.preview(modelFingerprint: model, modelLabel: "本地", progressBounded: false)
        XCTAssertFalse(whole.progressBounded); XCTAssertEqual(whole.chapters.count, 3); XCTAssertEqual(whole.sourceCharacters, 21)
        let before = await replies.sources; XCTAssertEqual(before.count, 2)
        let full = try await generate(store, plan: whole, replies: replies)
        XCTAssertTrue(full.visible(in: book)); XCTAssertFalse(full.progressBounded)
        let all = await replies.sources; XCTAssertEqual(all, [chapters[0].text, "小岚坐在", chapters[1].text, chapters[2].text])
        XCTAssertGreaterThan(try library.storageBytes(for: book), originalSize)
        let reopened = BookCharactersStore(library: try LibraryStore(root: root), bookID: book.id)
        XCTAssertEqual(try reopened.guide(), full)
        try store.delete()
        XCTAssertNil(try store.guide()); XCTAssertNil(try store.checkpoint())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.directory.path), [])
        XCTAssertEqual(try library.storageBytes(for: book), originalSize)
    }
    func testFailureKeepsPublishedGuideAndBackupResumesOnlyMissingParts() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), root = folder.appendingPathComponent("library")
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = try LibraryStore(root: root)
        var book = try library.importBook(title: "灯塔", chapters: [.init(id: 0, title: "一", text: "阿翎来到灯塔。"), .init(id: 1, title: "二", text: "小岚坐在窗边。")])
        book.readThrough = .init(offset: 7); try library.save(book)
        let store = BookCharactersStore(library: library, bookID: book.id)
        let saved = try await generate(store, plan: store.preview(modelFingerprint: model, modelLabel: "本地"), replies: Replies())
        let plan = try store.preview(modelFingerprint: model, modelLabel: "本地", progressBounded: false)
        do { _ = try await generate(store, plan: plan, replies: Replies(failure: "小岚")); XCTFail("Expected failure") } catch {}
        XCTAssertEqual(try store.guide(), saved); XCTAssertEqual(try store.checkpoint()?.completedParts, 1)
        let continuing = try store.preview(modelFingerprint: model, modelLabel: "本地", progressBounded: false)
        XCTAssertTrue(continuing.resuming); XCTAssertEqual(continuing.completedParts, 1)
        XCTAssertFalse(try store.preview(modelFingerprint: model, modelLabel: "本地").resuming)
        XCTAssertFalse(try store.preview(modelFingerprint: ChapterKnowledgeEntry.hash("other"), modelLabel: "另一个", progressBounded: false).resuming)
        let archive = folder.appendingPathComponent("characters.zip")
        _ = try await BackupArchive.create(root: root, output: archive)
        let prepared = try await BackupArchive.prepare(archive, beside: root)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        let restored = BookCharactersStore(library: try LibraryStore(root: prepared.directory), bookID: book.id)
        XCTAssertEqual(try restored.guide(), saved)
        let replies = Replies(), next = try restored.preview(modelFingerprint: model, modelLabel: "本地", progressBounded: false)
        XCTAssertTrue(next.resuming)
        let complete = try await generate(restored, plan: next, replies: replies)
        let sent = await replies.sources; XCTAssertEqual(sent, ["小岚坐在窗边。"])
        XCTAssertEqual(complete.characters.count, 2); XCTAssertNil(try restored.checkpoint())
    }
    func testCorruptCacheIsNotReusedAndSourceChangesInvalidatePlans() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), root = folder.appendingPathComponent("library")
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = try LibraryStore(root: root)
        var book = try library.importBook(title: "灯塔", chapters: [.init(id: 0, title: "一", text: "阿翎来到灯塔。")]); book.readThrough = .init(offset: 7); try library.save(book)
        let store = BookCharactersStore(library: library, bookID: book.id)
        let saved = try await generate(store, plan: store.preview(modelFingerprint: model, modelLabel: "本地"), replies: Replies())
        let cache = store.directory.appendingPathComponent("part-0-0.json")
        var data = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as? [String: Any]); data["sourceHash"] = ChapterKnowledgeEntry.hash("wrong")
        try JSONSerialization.data(withJSONObject: data).write(to: cache, options: .atomic)
        XCTAssertThrowsError(try store.validateBackup())
        let archive = folder.appendingPathComponent("invalid.zip")
        _ = try await BackupArchive.create(root: root, output: archive)
        do { _ = try await BackupArchive.prepare(archive, beside: root); XCTFail("Corrupt cache accepted") } catch {}
        let replies = Replies()
        _ = try await generate(store, plan: store.preview(modelFingerprint: model, modelLabel: "本地"), replies: replies)
        let sent = await replies.sources; XCTAssertEqual(sent.count, 1); try store.validateBackup()
        _ = try await generate(store, plan: store.preview(modelFingerprint: ChapterKnowledgeEntry.hash("new-model"), modelLabel: "新模型"), replies: replies)
        let changedModelSources = await replies.sources; XCTAssertEqual(changedModelSources.count, 2)
        let plan = try store.preview(modelFingerprint: model, modelLabel: "本地")
        let changed = Chapter(id: 0, title: "一", text: "阿翎走出了灯塔。")
        try JSONEncoder().encode(changed).write(to: library.directory(book.id).appendingPathComponent("chapter-0.json"), options: .atomic)
        book.chapters = [ChapterInfo(changed)]; try library.save(book)
        XCTAssertThrowsError(try store.validatePlan(plan)); XCTAssertFalse(saved.visible(in: book))
        let cleared = try library.clearBody(book)
        XCTAssertFalse(saved.visible(in: cleared)); XCTAssertNotNil(try store.guide())
        XCTAssertThrowsError(try store.preview(modelFingerprint: model, modelLabel: "本地"))
    }
    func testDuplicateGenerationAndCancellationLeaveResumableProgress() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try LibraryStore(root: root)
        let book = try library.importBook(title: "灯塔", chapters: [.init(id: 0, title: "一", text: "阿翎来到灯塔。")])
        let store = BookCharactersStore(library: library, bookID: book.id)
        let plan = try store.preview(modelFingerprint: model, modelLabel: "本地", progressBounded: false), replies = Replies(slow: true)
        let task = Task { try await self.generate(store, plan: plan, replies: replies) }
        for _ in 0..<100 { if !(await replies.sources).isEmpty { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        let other = BookCharactersStore(library: library, bookID: book.id)
        do { _ = try await generate(other, plan: plan, replies: Replies()); XCTFail("Duplicate generation accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("正在提取")) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation ignored") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(try store.guide())
        XCTAssertTrue(try store.preview(modelFingerprint: model, modelLabel: "本地", progressBounded: false).resuming)
        try store.delete(); XCTAssertNil(try store.checkpoint())
    }
}
