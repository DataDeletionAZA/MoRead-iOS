import XCTest
@testable import MoReadCore

final class ChapterKnowledgeTests: XCTestCase {
    private func draft(quote: String, outline: String = "阿翎抵达灯塔，看到窗边有光。", extras: [String: Any] = [:]) throws -> String {
        var value: [String: Any] = ["outline": outline, "summary": [["text": "灯塔亮起。", "quote": quote, "start": 999, "end": 1000]]]
        value.merge(extras) { _, new in new }
        return String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
    func testSplittingExactEvidenceAndProseValidation() throws {
        let text = String(repeating: "字", count: 9999) + "🌙" + String(repeating: "光", count: 9999) + "。\n" + String(repeating: "尾", count: 9000)
        let parts = try KnowledgePart.split(text)
        XCTAssertEqual(parts.map(\.text).joined(), text)
        XCTAssertEqual(parts[0].text.utf16.count, 9999)
        for (index, part) in parts.enumerated() {
            XCTAssertLessThanOrEqual(part.text.utf16.count, 10_000)
            XCTAssertEqual(part.start, parts.prefix(index).reduce(0) { $0 + $1.text.utf16.count })
            XCTAssertFalse(part.text.contains("�"))
        }
        let punctuation = try KnowledgePart.split(String(repeating: "甲", count: 8000) + "。" + String(repeating: "乙", count: 3000))
        XCTAssertEqual(punctuation[0].text.utf16.count, 8001)
        XCTAssertEqual(try KnowledgePart.split(String(repeating: "字", count: 60_000)).count, 6)
        XCTAssertThrowsError(try KnowledgePart.split(String(repeating: "字", count: 60_001)))
        XCTAssertThrowsError(try KnowledgePart.split(" \n\t"))
        let part = KnowledgePart(start: 10_000, text: "🌙阿翎来到灯塔。窗边灯光亮起。")
        let content = try ChapterKnowledge.parse("```json\n" + draft(quote: "阿翎来到灯塔。") + "\n```", part: part)
        XCTAssertEqual(content.summary[0].start, 10_002)
        XCTAssertEqual(content.summary[0].end, 10_009)
        XCTAssertThrowsError(try ChapterKnowledge.parse(draft(quote: "不存在的原文"), part: part))
        XCTAssertThrowsError(try ChapterKnowledge.parse(draft(quote: "哈哈哈哈"), part: .init(start: 0, text: "哈哈哈哈哈")))
        XCTAssertThrowsError(try ChapterKnowledge.parse(draft(quote: "café"), part: .init(start: 0, text: "cafe\u{301}")))
        XCTAssertThrowsError(try ChapterKnowledge.parse(draft(quote: "灯塔"), part: part))
        XCTAssertThrowsError(try ChapterKnowledge.parse(draft(quote: "阿翎来到灯塔。", outline: "- 抵达灯塔"), part: part))
        XCTAssertThrowsError(try ChapterKnowledge.parse(draft(quote: "阿翎来到灯塔。", outline: "1. 抵达灯塔"), part: part))
        XCTAssertThrowsError(try ChapterKnowledge.parse(draft(quote: "阿翎来到灯塔。", outline: String(repeating: "字", count: 901)), part: part, maximumOutline: 900))
        XCTAssertThrowsError(try ChapterKnowledge.parse(String(repeating: "字", count: 64_001), part: part))
        XCTAssertThrowsError(try ChapterKnowledge.parse(draft(quote: "阿翎来到灯塔。", extras: ["summary": []]), part: part))
        let character: [String: Any] = ["name": "阿翎", "facts": [["text": "抵达灯塔", "quote": "阿翎来到灯塔。"]]]
        let withCharacter = try ChapterKnowledge.parse(draft(quote: "阿翎来到灯塔。", extras: ["characters": [character]]), part: part)
        XCTAssertEqual(withCharacter.characters.first?.name, "阿翎")
        for name in ["她", "不存在的人"] {
            var invalid = character; invalid["name"] = name
            XCTAssertThrowsError(try ChapterKnowledge.parse(draft(quote: "阿翎来到灯塔。", extras: ["characters": [invalid]]), part: part))
        }
        XCTAssertThrowsError(try ChapterKnowledge.merge([withCharacter, withCharacter]))
        let merged = try ChapterKnowledge.merge([withCharacter, withCharacter], outline: "阿翎抵达灯塔。")
        XCTAssertEqual(merged.summary.count, 1); XCTAssertEqual(merged.characters[0].facts.count, 1)
    }
    func testFrozenReadScopeAtomicSaveLocateAndBackup() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("library"), store = try LibraryStore(root: root)
        let chapters = [Chapter(id: 0, title: "抵达", text: "🌙阿翎来到灯塔。窗边灯光亮起。"), Chapter(id: 1, title: "后来", text: "后来才知道的故事。")]
        var book = try store.importBook(title: "灯塔", chapters: chapters)
        XCTAssertThrowsError(try store.knowledgeSource(bookID: book.id, chapter: 0))
        book.readThrough = .init(offset: 9); try store.save(book)
        let source = try store.knowledgeSource(bookID: book.id, chapter: 0)
        XCTAssertEqual(source.text, "🌙阿翎来到灯塔。"); XCTAssertTrue(source.partial)
        XCTAssertEqual(source.requestCount, 1); XCTAssertEqual(source.maximumRequests, 2)
        XCTAssertThrowsError(try store.knowledgeSource(bookID: book.id, chapter: 1))
        let content = try ChapterKnowledge.parse(draft(quote: "阿翎来到灯塔。"), part: XCTUnwrap(source.parts.first))
        let model = ChapterKnowledgeEntry.hash("provider|endpoint|model")
        let entry = try store.saveKnowledge(content, source: source, modelFingerprint: model, modelLabel: "测试模型")
        XCTAssertTrue(entry.visible(in: book)); XCTAssertEqual(entry.sourceEnd, 9)
        XCTAssertEqual(try store.locateKnowledge(entry, fact: content.summary[0]).offset, 2)
        XCTAssertThrowsError(try store.locateKnowledge(entry, fact: .init(text: "伪造", quote: "窗边灯光亮起。", start: 9, end: 16)))
        try store.modifyRecords(for: book) { $0.bookmarks.append(.init(position: .init(), label: "保留")) }
        let other = try ChapterKnowledge.parse(draft(quote: "另一段真实原文。"), part: .init(start: 0, text: "另一段真实原文。"))
        XCTAssertThrowsError(try store.saveKnowledge(other, source: source, modelFingerprint: model, modelLabel: "测试模型"))
        XCTAssertEqual(try store.records(for: book).chapterKnowledge, [entry])
        book.readThrough = .init(offset: 1); try store.save(book)
        XCTAssertFalse(entry.visible(in: book))
        XCTAssertThrowsError(try store.validateKnowledgeSource(source))
        XCTAssertThrowsError(try store.saveKnowledge(content, source: source, modelFingerprint: model, modelLabel: "测试模型"))
        XCTAssertThrowsError(try store.locateKnowledge(entry, fact: content.summary[0]))
        book.readThrough = .init(offset: chapters[0].text.utf16.count); try store.save(book)
        try store.validateKnowledgeSource(source)
        XCTAssertTrue(entry.visible(in: book))
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            XCTAssertThrowsError(try store.saveKnowledge(content, source: source, modelFingerprint: model, modelLabel: "测试模型"))
        }
        try await cancelled.value
        XCTAssertEqual(try store.records(for: book).chapterKnowledge, [entry])
        XCTAssertEqual(try LibraryStore(root: root).records(for: book).chapterKnowledge, [entry])
        let archive = temporary.appendingPathComponent("knowledge.zip")
        _ = try await BackupArchive.create(root: root, output: archive)
        let restored = try await BackupArchive.prepare(archive, beside: root)
        defer { try? FileManager.default.removeItem(at: restored.directory) }
        XCTAssertEqual(try LibraryStore(root: restored.directory).records(for: book).chapterKnowledge, [entry])
        try store.deleteKnowledge(bookID: book.id, chapter: 0)
        XCTAssertEqual(try store.records(for: book).chapterKnowledge, [])
        XCTAssertEqual(try store.records(for: book).bookmarks.count, 1)
        _ = try store.saveKnowledge(content, source: source, modelFingerprint: model, modelLabel: "测试模型")
        let cleared = try store.clearBody(book)
        XCTAssertEqual(try store.records(for: cleared).chapterKnowledge?.count, 1)
        XCTAssertFalse(entry.visible(in: cleared))
        XCTAssertThrowsError(try store.knowledgeSource(bookID: book.id, chapter: 0))
    }
    func testChangedOtherChapterAndCorruptBackupAreRejected() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("library"), store = try LibraryStore(root: root)
        let chapters = [Chapter(id: 0, title: "一", text: "阿翎来到灯塔。"), Chapter(id: 1, title: "二", text: "其他章节。")]
        var book = try store.importBook(title: "灯塔", chapters: chapters)
        book.readThrough = .init(offset: 7); try store.save(book)
        let source = try store.knowledgeSource(bookID: book.id, chapter: 0)
        let content = try ChapterKnowledge.parse(draft(quote: source.text), part: XCTUnwrap(source.parts.first))
        let entry = try store.saveKnowledge(content, source: source, modelFingerprint: ChapterKnowledgeEntry.hash("test"), modelLabel: "本地")
        let old = book
        book.chapters[1].revision = ChapterKnowledgeEntry.hash("changed"); try store.save(book)
        XCTAssertFalse(entry.visible(in: book)); XCTAssertThrowsError(try store.validateKnowledgeSource(source))
        try store.save(old); book = old
        var records = try store.records(for: book)
        records.chapterKnowledge = [entry, entry]; try store.saveRecords(records, for: book)
        let duplicate = temporary.appendingPathComponent("duplicate.zip")
        _ = try await BackupArchive.create(root: root, output: duplicate)
        do { _ = try await BackupArchive.prepare(duplicate, beside: root); XCTFail("Duplicate chapter accepted") } catch {}
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        object["sourceHash"] = ChapterKnowledgeEntry.hash("altered")
        let corrupt = try JSONDecoder().decode(ChapterKnowledgeEntry.self, from: JSONSerialization.data(withJSONObject: object))
        records.chapterKnowledge = [corrupt]; try store.saveRecords(records, for: book)
        let damaged = temporary.appendingPathComponent("damaged.zip")
        _ = try await BackupArchive.create(root: root, output: damaged)
        do { _ = try await BackupArchive.prepare(damaged, beside: root); XCTFail("Invalid source hash accepted") } catch {}
        let legacy = try JSONDecoder().decode(BookRecords.self, from: Data(#"{"annotations":[],"bookmarks":[],"readingSeconds":{}}"#.utf8))
        XCTAssertNil(legacy.chapterKnowledge)
    }
    private actor StreamProbe {
        var rounds: [ChatToolRound]
        var calls = 0
        var repaired = false
        var valid = true
        var inFlight = 0
        var maximum = 0
        var cancelled = 0
        init(_ rounds: [ChatToolRound] = []) { self.rounds = rounds }
        func next(_ exchanges: [ChatToolExchange]) throws -> ChatToolRound {
            calls += 1
            if exchanges.first?.results.first?.failed == true { repaired = true }
            guard !rounds.isEmpty else { throw MoReadError.invalid("模拟服务失败") }
            return rounds.removeFirst()
        }
        func invalidate() { valid = false }
        func validate() throws { if !valid { throw MoReadError.invalid("原文已变化") } }
        func enter() { inFlight += 1; maximum = max(maximum, inFlight) }
        func leave() { inFlight -= 1 }
        func interrupted() { cancelled += 1 }
    }
    func testLongChapterToolCorrectionCompositionAndFailurePreservesOldEntry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let body = "阿翎来到灯塔。" + String(repeating: "甲", count: 9993) + "窗边灯光亮起。" + String(repeating: "乙", count: 20)
        var book = try store.importBook(title: "灯塔", chapters: [.init(id: 0, title: "长章", text: body)])
        book.readThrough = .init(offset: body.utf16.count); try store.save(book)
        let source = try store.knowledgeSource(bookID: book.id, chapter: 0)
        XCTAssertEqual(source.parts.count, 2); XCTAssertEqual(source.requestCount, 3); XCTAssertEqual(source.maximumRequests, 6)
        func round(_ raw: String, tool: String = "save_chapter_knowledge") -> ChatToolRound {
            .init(text: "", calls: [.init(id: UUID().uuidString, name: tool, arguments: raw)], replay: Data("{}".utf8))
        }
        let probe = StreamProbe([
            round(try draft(quote: "编造的原文。")), round(try draft(quote: "阿翎来到灯塔。")),
            round(try draft(quote: "窗边灯光亮起。", outline: "窗边有灯光。")),
            round(#"{"outline":"阿翎抵达灯塔，看到窗边的灯光。"}"#, tool: "save_chapter_outline")])
        let content = try await ChapterKnowledgeAgent.generate(source: source, stream: { _, _, exchanges in try await probe.next(exchanges) }, validate: {})
        let calls = await probe.calls, repaired = await probe.repaired
        XCTAssertEqual(calls, 4); XCTAssertTrue(repaired)
        XCTAssertEqual(content.outline, "阿翎抵达灯塔，看到窗边的灯光。")
        XCTAssertEqual(content.summary.map(\.start), [0, 10_000])
        let entry = try store.saveKnowledge(content, source: source, modelFingerprint: ChapterKnowledgeEntry.hash("test"), modelLabel: "测试")
        let bad = StreamProbe([round(try draft(quote: "第一条错误依据")), round(try draft(quote: "第二条错误依据"))])
        do {
            let replacement = try await ChapterKnowledgeAgent.generate(source: source, stream: { _, _, exchanges in try await bad.next(exchanges) }, validate: {})
            _ = try store.saveKnowledge(replacement, source: source, modelFingerprint: ChapterKnowledgeEntry.hash("test"), modelLabel: "测试")
            XCTFail("Invalid evidence accepted")
        } catch {}
        let badCalls = await bad.calls
        XCTAssertEqual(badCalls, 2)
        XCTAssertEqual(try store.records(for: book).chapterKnowledge, [entry])
        let laterFailure = StreamProbe([round(try draft(quote: "阿翎来到灯塔。"))])
        do {
            let replacement = try await ChapterKnowledgeAgent.generate(source: source, stream: { _, _, exchanges in try await laterFailure.next(exchanges) }, validate: {})
            _ = try store.saveKnowledge(replacement, source: source, modelFingerprint: ChapterKnowledgeEntry.hash("test"), modelLabel: "测试")
            XCTFail("Partial result replaced complete outline")
        } catch {}
        XCTAssertEqual(try store.records(for: book).chapterKnowledge, [entry])
    }
    func testGenerationRevalidatesAfterNetworkTimesOutAndLimitsConcurrency() async throws {
        let probe = StreamProbe(), tool = ChatTool(name: "save", description: "", parameters: Data("{}".utf8))
        do {
            _ = try await ChapterKnowledgeAgent.submit(messages: [], tool: tool, stream: { _, _, _ in
                await probe.invalidate()
                return .init(text: "valid", calls: [], replay: Data("{}".utf8))
            }, validate: { try await probe.validate() }, parse: { $0 })
            XCTFail("Changed source accepted")
        } catch { XCTAssertEqual(error.localizedDescription, "原文已变化") }
        do {
            _ = try await ChapterKnowledgeAgent.submit(messages: [], tool: tool, stream: { _, _, _ in
                do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                catch { await probe.interrupted(); throw error }
                return .init(text: "late", calls: [], replay: Data("{}".utf8))
            }, validate: {}, timeout: 10_000_000, parse: { $0 })
            XCTFail("Timeout ignored")
        } catch { XCTAssertTrue(error.localizedDescription.contains("超时")) }
        let interrupted = await probe.cancelled; XCTAssertEqual(interrupted, 1)
        let limiter = KnowledgeRequestLimiter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await limiter.request {
                        await probe.enter()
                        try await Task.sleep(nanoseconds: 10_000_000)
                        await probe.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        let maximum = await probe.maximum, running = await probe.inFlight
        XCTAssertEqual(maximum, 2); XCTAssertEqual(running, 0)
        let occupied = (0..<2).map { _ in Task {
            try await limiter.request {
                await probe.enter()
                try await Task.sleep(nanoseconds: 200_000_000)
                await probe.leave()
            }
        } }
        for _ in 0..<100 {
            if await probe.inFlight == 2 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let queued = Task { try await limiter.request { "unexpected" } }
        try await Task.sleep(nanoseconds: 10_000_000); queued.cancel()
        do { _ = try await queued.value; XCTFail("Queued cancellation ignored") } catch { XCTAssertTrue(error is CancellationError) }
        for task in occupied { try await task.value }
        let result = try await limiter.request { 42 }; XCTAssertEqual(result, 42)
        let fallback = try await ChapterKnowledgeAgent.submit(messages: [], tool: tool, stream: { _, _, _ in .init(text: "文本结果", calls: [], replay: Data("{}".utf8)) }, validate: {}, parse: { $0 })
        XCTAssertEqual(fallback, "文本结果")
    }

}
