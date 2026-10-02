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
    private func profileFixture() -> (first: String, second: String, replies: [String: String]) {
        let first = "阿翎又名小翎，是二十岁的女店主，穿着蓝衣。小岚是阿翎的师父。", second = "小翎打开灯塔的大门。江舟向小翎递出了信。"
        let one = #"{"characters":[{"name":"阿翎","facts":[{"text":"经营店铺","quote":"阿翎又名小翎，是二十岁的女店主，穿着蓝衣。"}],"attributes":[{"kind":"ALIAS","value":"小翎","quote":"阿翎又名小翎，是二十岁的女店主，穿着蓝衣。"},{"kind":"AGE","value":"二十岁","quote":"阿翎又名小翎，是二十岁的女店主，穿着蓝衣。"},{"kind":"GENDER","value":"女","quote":"阿翎又名小翎，是二十岁的女店主，穿着蓝衣。"},{"kind":"IDENTITY","value":"店主","quote":"阿翎又名小翎，是二十岁的女店主，穿着蓝衣。"},{"kind":"APPEARANCE","value":"蓝衣","quote":"阿翎又名小翎，是二十岁的女店主，穿着蓝衣。"}],"relationships":[{"target":"小岚","relation":"徒弟","quote":"小岚是阿翎的师父。"}]}]}"#
        let two = #"{"characters":[{"name":"小翎","facts":[{"text":"打开灯塔","quote":"小翎打开灯塔的大门。"}]},{"name":"江舟","facts":[{"text":"送来信件","quote":"江舟向小翎递出了信。"}],"relationships":[{"target":"小翎","relation":"送信人","quote":"江舟向小翎递出了信。"}]}]}"#
        return (first, second, [first: one, second: two])
    }
    private actor ProfileReplies {
        let replies: [String: String]
        var sources: [String] = []
        init(_ replies: [String: String]) { self.replies = replies }
        func reply(_ messages: [ChatMessage], tool: ChatTool) throws -> ChatToolRound {
            let source = messages.last!.content.components(separatedBy: "<source>\n").last!.components(separatedBy: "\n</source>").first!
            sources.append(source)
            guard let raw = replies[source] else { throw MoReadError.invalid("Unexpected test source") }
            return .init(text: "", calls: [.init(id: UUID().uuidString, name: tool.name, arguments: raw)], replay: Data("{}".utf8))
        }
    }
    func testStructuredCharacterParsingAliasesAndAmbiguousNames() throws {
        let fixture = profileFixture(), raw = fixture.replies[fixture.first]!, part = KnowledgePart(start: 0, text: fixture.first)
        let first = try ChapterKnowledge.parseCharacters(raw, part: part)
        XCTAssertEqual(first[0].attributes.map(\.kind), [.alias, .age, .gender, .identity, .appearance])
        XCTAssertEqual(first[0].relationships.first?.relation, "徒弟"); try ChapterKnowledge.validateCharacters(first, part: part)
        for invalid in [raw.replacingOccurrences(of: "\"AGE\"", with: "\"UNKNOWN\""),
                        raw.replacingOccurrences(of: "\"value\":\"小翎\"", with: "\"value\":\"小岚\""),
                        raw.replacingOccurrences(of: "\"target\":\"小岚\"", with: "\"target\":\"阿翎\""),
                        raw.replacingOccurrences(of: "\"value\":\"二十岁\"", with: "\"value\":\"" + String(repeating: "字", count: 81) + "\"")] {
            XCTAssertThrowsError(try ChapterKnowledge.parseCharacters(invalid, part: part))
        }
        var accumulator = BookCharacterAccumulator(); accumulator.add(chapter: 0, characters: first)
        accumulator.add(chapter: 1, characters: try ChapterKnowledge.parseCharacters(fixture.replies[fixture.second]!, part: .init(start: 0, text: fixture.second)))
        XCTAssertEqual(accumulator.characters.map(\.name), ["阿翎", "江舟"])
        XCTAssertEqual(accumulator.characters[0].evidence.map(\.chapter), [0, 1])
        XCTAssertEqual(accumulator.characters[1].relationships.first?.target, "阿翎")
        XCTAssertEqual(accumulator.characters[1].relationships.first?.sourceTarget, "小翎")
        let shared = #"{"characters":[{"name":"小岚","facts":[{"text":"有共同称呼","quote":"小岚又名小翎。"}],"attributes":[{"kind":"ALIAS","value":"小翎","quote":"小岚又名小翎。"}]}]}"#
        accumulator.add(chapter: 2, characters: try ChapterKnowledge.parseCharacters(shared, part: .init(start: 0, text: "小岚又名小翎。")))
        XCTAssertEqual(accumulator.characters.map(\.name), ["阿翎", "小翎", "江舟", "小岚"])
        var cycle = BookCharacterAccumulator()
        let cyclic = #"{"characters":[{"name":"甲","facts":[{"text":"称呼甲","quote":"甲又名乙。"}],"attributes":[{"kind":"ALIAS","value":"乙","quote":"甲又名乙。"}]},{"name":"乙","facts":[{"text":"称呼乙","quote":"乙又名甲。"}],"attributes":[{"kind":"ALIAS","value":"甲","quote":"乙又名甲。"}]}]}"#
        cycle.add(chapter: 0, characters: try ChapterKnowledge.parseCharacters(cyclic, part: .init(start: 0, text: "甲又名乙。乙又名甲。")))
        XCTAssertEqual(cycle.characters.map(\.name), ["甲", "乙"])
        let legacy = try JSONDecoder().decode(KnowledgeCharacter.self, from: Data(#"{"name":"阿翎","facts":[]}"#.utf8))
        XCTAssertTrue(legacy.attributes.isEmpty); XCTAssertTrue(legacy.relationships.isEmpty)
    }
    func testStructuredProfilesScopeCacheUpgradeBackupAndManualEditing() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), root = folder.appendingPathComponent("library")
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = profileFixture(), replies = ProfileReplies(fixture.replies), library = try LibraryStore(root: root)
        var book = try library.importBook(title: "灯塔", chapters: [.init(id: 0, title: "一", text: fixture.first), .init(id: 1, title: "二", text: fixture.second)])
        book.readThrough = .init(offset: fixture.first.utf16.count); try library.save(book)
        let store = BookCharactersStore(library: library, bookID: book.id)
        func generate() async throws -> BookCharacterGuide {
            try await store.generate(store.preview(modelFingerprint: model, modelLabel: "本地"), stream: { messages, tool, _ in try await replies.reply(messages, tool: tool) }, validate: {})
        }
        let first = try await generate()
        XCTAssertEqual(first.characters.map(\.name), ["阿翎"]); XCTAssertEqual(first.characters[0].attributes.count, 5)
        XCTAssertEqual(try store.locate(first, evidence: first.characters[0].attributes[1].evidence).chapter, 0)
        let cache = store.directory.appendingPathComponent("part-0-0.json")
        var legacyCache = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as? [String: Any]); legacyCache["promptVersion"] = 1
        try JSONSerialization.data(withJSONObject: legacyCache).write(to: cache, options: .atomic)
        _ = try await generate(); let retried = await replies.sources; XCTAssertEqual(retried, [fixture.first, fixture.first])
        book.readThrough = .init(chapter: 1, offset: fixture.second.utf16.count); try library.save(book)
        let full = try await generate(); let sent = await replies.sources; XCTAssertEqual(sent.count, 3)
        XCTAssertEqual(full.characters.map(\.name), ["阿翎", "江舟"]); try store.validateBackup()
        XCTAssertEqual(try store.locate(full, evidence: full.characters[1].relationships[0].evidence).chapter, 1)
        let edited = try store.saveCharacter(expected: full, originalIdentity: "阿翎", name: "灯塔主人", description: "手写内容")
        XCTAssertEqual(edited.characters[0].attributes.count, 5)
        let card = try store.extractedCard(from: edited, named: "灯塔主人").characterCard()
        XCTAssertTrue(card.description.contains("外貌：蓝衣")); XCTAssertTrue(card.description.contains("小岚：徒弟")); XCTAssertTrue(card.description.contains("手写内容"))
        let archive = folder.appendingPathComponent("profile.zip"); _ = try await BackupArchive.create(root: root, output: archive)
        let restored = try await BackupArchive.prepare(archive, beside: root)
        defer { try? FileManager.default.removeItem(at: restored.directory) }
        XCTAssertEqual(try BookCharactersStore(library: LibraryStore(root: restored.directory), bookID: book.id).guide(), edited)
        book.readThrough = .init(); try library.save(book)
        let visible = edited.displayedCharacters(in: book)
        XCTAssertEqual(visible.count, 1); XCTAssertTrue(visible[0].attributes.isEmpty); XCTAssertTrue(visible[0].relationships.isEmpty)
        XCTAssertEqual(try store.extractedCard(from: edited, named: "灯塔主人").description, "手写内容")
        XCTAssertThrowsError(try store.locate(edited, evidence: edited.characters[0].attributes[0].evidence))
    }
    func testManualProfilesSurviveGenerationRenamingBackupAndSourceChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try LibraryStore(root: root)
        var book = try library.importBook(title: "灯塔", chapters: [.init(id: 0, title: "一", text: "阿翎来到灯塔。")])
        book.readThrough = .init(offset: 7); try library.save(book)
        let store = BookCharactersStore(library: library, bookID: book.id)
        let manual = try store.saveCharacter(expected: nil, originalIdentity: nil, name: " 阿翎 ", description: " 手写人设 ")
        XCTAssertEqual(manual.scannedChapters, 0)
        XCTAssertEqual(try store.extractedCard(from: manual, named: "阿翎").characterCard().description, "手写人设")
        try store.validateBackup()
        XCTAssertThrowsError(try store.saveCharacter(expected: nil, originalIdentity: nil, name: "新人物", description: "过期编辑"))
        XCTAssertThrowsError(try store.saveCharacter(expected: manual, originalIdentity: nil, name: "阿翎", description: "重名"))
        XCTAssertThrowsError(try store.saveCharacter(expected: manual, originalIdentity: nil, name: "a" + String(repeating: "\u{0301}", count: 80), description: ""))
        XCTAssertThrowsError(try store.saveCharacter(expected: manual, originalIdentity: nil, name: "新人物", description: String(repeating: "字", count: 24_001)))
        let generated = try await generate(store, plan: store.preview(modelFingerprint: model, modelLabel: "本地"), replies: Replies())
        XCTAssertEqual(generated.characters[0].manualDescription, "手写人设"); XCTAssertEqual(generated.characters[0].evidence.count, 1)
        let renamed = try store.saveCharacter(expected: generated, originalIdentity: "阿翎", name: "灯塔主人", description: "温柔的朋友")
        XCTAssertEqual(renamed.characters[0].id, "阿翎"); try store.validateBackup()
        XCTAssertThrowsError(try store.saveCharacter(expected: renamed, originalIdentity: nil, name: "阿翎", description: "重名"))
        let archive = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".zip")
        defer { try? FileManager.default.removeItem(at: archive) }
        _ = try await BackupArchive.create(root: root, output: archive)
        let restored = try await BackupArchive.prepare(archive, beside: root)
        defer { try? FileManager.default.removeItem(at: restored.directory) }
        XCTAssertEqual(try BookCharactersStore(library: LibraryStore(root: restored.directory), bookID: book.id).guide(), renamed)
        let updated = try await generate(store, plan: store.preview(modelFingerprint: model, modelLabel: "本地"), replies: Replies())
        XCTAssertEqual(updated.characters, renamed.characters)
        book.readThrough = .init(); try library.save(book)
        XCTAssertEqual(updated.displayedCharacters(in: book).first?.evidence, [])
        XCTAssertEqual(try store.extractedCard(from: updated, named: "灯塔主人").description, "温柔的朋友")
        let changed = Chapter(id: 0, title: "一", text: "小岚坐在窗边。")
        try JSONEncoder().encode(changed).write(to: library.directory(book.id).appendingPathComponent("chapter-0.json"), options: .atomic)
        book.chapters = [ChapterInfo(changed)]; book.readThrough = .init(offset: 7); try library.save(book)
        let replaced = try await generate(store, plan: store.preview(modelFingerprint: model, modelLabel: "本地"), replies: Replies())
        XCTAssertEqual(replaced.characters.map(\.name), ["小岚", "灯塔主人"])
        XCTAssertEqual(replaced.characters.last?.evidence, []); XCTAssertEqual(replaced.characters.last?.manualDescription, "温柔的朋友")
        try store.validateBackup(); try store.delete(); XCTAssertNil(try store.guide())
    }
    func testManualEditDuringExtractionAndLegacyGuideDecoding() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try LibraryStore(root: root)
        let book = try library.importBook(title: "灯塔", chapters: [.init(id: 0, title: "一", text: "阿翎来到灯塔。")])
        let store = BookCharactersStore(library: library, bookID: book.id), replies = Replies()
        let plan = try store.preview(modelFingerprint: model, modelLabel: "本地", progressBounded: false)
        let generated = try await store.generate(plan, stream: { messages, tool, _ in
            try await MainActor.run { _ = try store.saveCharacter(expected: nil, originalIdentity: nil, name: "阿翎", description: "提取时写入") }
            return try await replies.reply(messages, tool: tool)
        }, validate: {})
        XCTAssertEqual(generated.characters.first?.manualDescription, "提取时写入")
        XCTAssertEqual(generated.characters.first?.evidence.count, 1)
        let legacy = try JSONDecoder().decode(BookCharacter.self, from: Data(#"{"name":"阿翎","evidence":[]}"#.utf8))
        XCTAssertNil(legacy.manualDescription); XCTAssertNil(legacy.sourceName); XCTAssertEqual(legacy.id, "阿翎")
        let merged = BookCharacterGuide.mergingManual([.init(name: "阿翎", evidence: []), .init(name: "灯塔主人", evidence: [])], previous: [.init(name: "灯塔主人", evidence: [], manualDescription: "保留", sourceName: "阿翎")])
        XCTAssertEqual(merged.count, 1); XCTAssertEqual(merged.first?.id, "阿翎")
    }
    func testExtractedCardRoundTripBackupEditsAndStaleSourceRejection() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), root = folder.appendingPathComponent("library")
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = try LibraryStore(root: root), companions = try CompanionStore(root: root)
        var book = try library.importBook(title: "灯塔", chapters: [.init(id: 0, title: "一", text: "阿翎来到灯塔。"), .init(id: 1, title: "二", text: "小岚守着来信。")])
        book.readThrough = .init(offset: 7); try library.save(book)
        let store = BookCharactersStore(library: library, bookID: book.id)
        let guide = try await generate(store, plan: store.preview(modelFingerprint: model, modelLabel: "本地"), replies: Replies())
        var draft = try store.extractedCard(from: guide, named: "阿翎")
        XCTAssertEqual(try companions.characters().count, 0)
        XCTAssertTrue(draft.description.contains("第 1 章依据：阿翎来到灯塔。")); XCTAssertFalse(draft.description.contains("小岚"))
        XCTAssertThrowsError(try store.extractedCard(from: guide, named: "小岚"))
        draft.name = "  灯塔的阿翎  "; draft.description += "\n说话温柔。"
        let card = try draft.characterCard(), data = try draft.json()
        XCTAssertEqual(card.id, draft.id); XCTAssertEqual(card.name, "灯塔的阿翎"); XCTAssertTrue(card.greeting.isEmpty)
        let imported = try CharacterCardImporter.parse(data)
        XCTAssertEqual(imported.name, card.name); XCTAssertEqual(imported.description, card.description)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["spec"] as? String, "chara_card_v2")
        try companions.save(card); try companions.save(draft.characterCard())
        XCTAssertEqual(try companions.characters(), [card])
        let archive = folder.appendingPathComponent("cards.zip")
        _ = try await BackupArchive.create(root: root, output: archive)
        let restored = try await BackupArchive.prepare(archive, beside: root)
        defer { try? FileManager.default.removeItem(at: restored.directory) }
        XCTAssertEqual(try CompanionStore(root: restored.directory).characters(), [card])
        var invalid = draft; invalid.name = " \n"; XCTAssertThrowsError(try invalid.json())
        invalid.name = String(repeating: "名", count: 81); XCTAssertThrowsError(try invalid.characterCard())
        invalid.name = "a" + String(repeating: "\u{0301}", count: 80); XCTAssertThrowsError(try invalid.json())
        invalid = draft; invalid.description = ""; XCTAssertThrowsError(try invalid.json())
        invalid.description = String(repeating: "字", count: 24_001); XCTAssertThrowsError(try invalid.json())
        book.readThrough = .init(); try library.save(book)
        XCTAssertThrowsError(try store.extractedCard(from: guide, named: "阿翎"))
        book.readThrough = .init(offset: 7); try library.save(book)
        let changed = Chapter(id: 0, title: "一", text: "阿翎离开灯塔。")
        try JSONEncoder().encode(changed).write(to: library.directory(book.id).appendingPathComponent("chapter-0.json"), options: .atomic)
        XCTAssertThrowsError(try store.extractedCard(from: guide, named: "阿翎"))
        try store.delete(); XCTAssertThrowsError(try store.extractedCard(from: guide, named: "阿翎"))
    }
}
