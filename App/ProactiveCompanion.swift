import Foundation
import MoReadCore

extension CompanionModel {
    func stopAnnotations() { annotationTask?.cancel() }
    func setAnnotationReader(_ id: UUID?, library: LibraryModel) {
        if annotationReaderID != id { stopAnnotations(); annotationReaderID = id }
        if let id { generateAnnotations(bookID: id, library: library) }
    }
    func generateAnnotations(bookID: UUID, library: LibraryModel) {
        let policy = (settings.proactive ?? ProactiveSettings()).validated()
        guard policy.enabled, annotationReaderID == bookID, annotationTask == nil, !library.maintenance,
              let book = library.books.first(where: { $0.id == bookID && !$0.removed && $0.hasBody }),
              let chapterIndex = book.chapters.indices.last(where: { $0 <= book.position.chapter && ReadingPosition(chapter: $0, offset: book.chapters[$0].length) <= book.readThrough }),
              let libraryStore = library.store else { return }
        annotationBookID = bookID
        guard let provider = settings.resolvedProvider(for: .annotation) else { annotationStatus = "请先为随读段评选择 AI 服务商。"; return }
        let ids = policy.characterIDs.isEmpty ? [settings.selectedCharacter].compactMap { $0 } : policy.characterIDs
        let cards = characters.filter { ids.contains($0.id) }
        guard !cards.isEmpty else { annotationStatus = "请先选择参与段评的角色。"; return }
        do {
            let key: String
            #if DEBUG
            if simulatedAnnotations { key = "local-test" } else { key = try KeychainStore.read(provider.id) }
            #else
            key = try KeychainStore.read(provider.id)
            #endif
            _ = try ChatRequest.make(provider: provider, key: key, messages: [.init(role: "user", content: "段评配置检查")])
            let chapter = try libraryStore.chapter(chapterIndex, in: book)
            let identity = settings.currentIdentity
            annotationRunning = true; annotationStatus = "正在准备随读段评…"
            annotationTask = Task {
                defer {
                    self.annotationTask = nil; self.annotationRunning = false
                    if let nextBook = self.annotationReaderID, nextBook != bookID {
                        self.generateAnnotations(bookID: nextBook, library: library)
                    } else if let current = library.books.first(where: { $0.id == bookID }),
                       let completed = current.chapters.indices.last(where: { $0 <= current.position.chapter && ReadingPosition(chapter: $0, offset: current.chapters[$0].length) <= current.readThrough }),
                       completed != chapterIndex || (self.settings.proactive ?? ProactiveSettings()).validated() != policy {
                        self.generateAnnotations(bookID: bookID, library: library)
                    }
                }
                var created = 0
                do {
                    let ceiling = policy.maximumPerChapter == -1 ? Int.max : policy.maximumPerChapter
                    let candidates = ProactiveAnnotations.candidates(in: chapter.text, limit: ceiling)
                    for (cardIndex, card) in cards.enumerated() {
                        let records = try libraryStore.records(for: book)
                        let existing = records.annotations.filter { $0.characterID != nil && $0.passage.chapter == chapterIndex && $0.passage.revision == chapter.revision }.count
                        let available = max(0, ceiling - existing)
                        let share = ceiling == Int.max ? Int.max : (available + cards.count - cardIndex - 1) / (cards.count - cardIndex)
                        var countForCard = 0
                        for target in candidates {
                            try Task.checkCancellation()
                            guard self.annotationAllowed(book: book, card: card, provider: provider, policy: policy, identity: identity, library: library) else { throw CancellationError() }
                            guard countForCard < share else { break }
                            let latest = try libraryStore.records(for: book)
                            let jobKey = ProactiveAnnotations.key(chapter: chapter, target: target, characterID: card.id)
                            let attempt = latest.annotationAttempts?[jobKey] ?? ProactiveAttempt()
                            guard attempt.canStart(), !latest.annotations.contains(where: { $0.generationKey == jobKey }) else { continue }
                            // ponytail: scan book records for the daily quota; add a daily index if large libraries delay generation.
                            let today = try library.books.reduce(0) { count, value in
                                count + (try libraryStore.records(for: value)).annotations.filter { $0.characterID != nil && Calendar.current.isDateInToday($0.createdAt) }.count
                            }
                            if policy.dailyMaximum != -1, today >= policy.dailyMaximum { self.annotationStatus = "今日段评额度已用完。"; return }
                            var bounded = book; bounded.readThrough = .init(chapter: chapterIndex, offset: target.start)
                            let query = (chapter.text as NSString).substring(with: target.range)
                            let root = libraryStore.root
                            let backgroundTask = Task.detached(priority: .utility) {
                                try CompanionContextBuilder.build(query: query, books: [bounded], currentBook: book.id, store: LibraryStore(root: root)).text
                            }
                            let background = try await withTaskCancellationHandler { try await backgroundTask.value } onCancel: { backgroundTask.cancel() }
                            try Task.checkCancellation()
                            guard self.annotationAllowed(book: book, card: card, provider: provider, policy: policy, identity: identity, library: library) else { throw CancellationError() }
                            try library.modifyRecords(for: book) { value in
                                var next = attempt; next.count += 1; next.updatedAt = Date()
                                if value.annotationAttempts == nil { value.annotationAttempts = [:] }
                                value.annotationAttempts?[jobKey] = next
                            }
                            self.annotationStatus = "\(card.name)正在读《\(book.title)》…"
                            do {
                                let messages = try ProactiveAnnotations.messages(chapter: chapter, target: target, card: card, user: identity.name, background: background, minimum: policy.minimumPerChapter, identity: identity)
                                let raw = try await self.annotationReply(provider: provider, key: key, messages: messages, target: query)
                                try Task.checkCancellation()
                                guard self.annotationAllowed(book: book, card: card, provider: provider, policy: policy, identity: identity, library: library) else { throw CancellationError() }
                                let currentChapter = try libraryStore.chapter(chapterIndex, in: book)
                                guard currentChapter.revision == chapter.revision else { throw CancellationError() }
                                let note = try ProactiveAnnotations.annotation(from: raw, bookID: bookID, chapter: chapter, target: target, character: card)
                                try library.modifyRecords(for: book) { value in
                                    if !value.annotations.contains(where: { $0.generationKey == jobKey }) { value.annotations.append(note) }
                                    value.annotationAttempts?[jobKey]?.completed = true
                                }
                                created += 1; countForCard += 1
                            } catch is CancellationError { throw CancellationError() }
                            catch {
                                if Task.isCancelled { throw CancellationError() }
                                self.annotationStatus = error.localizedDescription
                            }
                        }
                    }
                    if created > 0 { self.annotationStatus = "已保存 \(created) 条随读段评，可在“批注”查看。" }
                    else if self.annotationStatus == "正在准备随读段评…" { self.annotationStatus = "本章已处理的段落会自动跳过。" }
                } catch is CancellationError { self.annotationStatus = "随读段评已停止。" }
                catch { self.annotationStatus = error.localizedDescription }
            }
        } catch { annotationStatus = error.localizedDescription }
    }
    #if DEBUG
    var simulatedAnnotations: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-testing") && ProcessInfo.processInfo.arguments.contains("--simulate-annotations")
    }
    #endif
    private func annotationReply(provider: AIProvider, key: String, messages: [ChatMessage], target: String) async throws -> String {
        #if DEBUG
        if simulatedAnnotations {
            let reply = ["quote": TextBoundary.prefix(target, end: 30), "note": "这是一条本地模拟的随读段评。", "style": "UNDERLINE"]
            return String(decoding: try JSONSerialization.data(withJSONObject: reply), as: UTF8.self)
        }
        #endif
        return try await ChatClient.complete(provider: provider, key: key, messages: messages, maximumBytes: 64 * 1024)
    }
    private func annotationAllowed(book: Book, card: CharacterCard, provider: AIProvider, policy: ProactiveSettings, identity: ChatIdentity, library: LibraryModel) -> Bool {
        annotationReaderID == book.id && !library.maintenance && (settings.proactive ?? ProactiveSettings()).validated() == policy && settings.currentIdentity == identity &&
        (policy.characterIDs.isEmpty ? settings.selectedCharacter == card.id : policy.characterIDs.contains(card.id)) && characters.contains(card) && settings.resolvedProvider(for: .annotation) == provider &&
        library.books.contains { $0.id == book.id && !$0.removed && $0.hasBody && $0.readThrough >= book.readThrough && $0.chapters.map(\.revision) == book.chapters.map(\.revision) }
    }
}
