import SwiftUI
import MoReadCore

extension CompanionModel {
    func translate(bookID: UUID, source: Chapter, range: NSRange?, replace: Bool, library: LibraryModel) {
        guard translationTasks[bookID] == nil, !library.maintenance, let storage = library.store else { return }
        let provider = settings.resolvedProvider(for: .translation)
        library.flush(); translatingBooks.insert(bookID); translationStates[bookID] = "正在准备翻译…"
        translationTasks[bookID] = Task {
            defer { self.translationTasks[bookID] = nil; self.translatingBooks.remove(bookID); library.recordsRevision = UUID() }
            do {
                let store = ParagraphTranslationStore(library: storage, bookID: bookID)
                try await store.generate(source: source, range: range, replaceCached: replace, complete: { messages in
                    try await self.translationReply(provider: provider, messages: messages)
                }, validate: {
                    try await self.validateTranslation(bookID: bookID, provider: provider, storage: storage, library: library)
                }, progress: { done, total in
                    await self.translationProgress(bookID: bookID, done: done, total: total, library: library)
                })
                self.translationStates[bookID] = "译文已保存，可随时隐藏或显示。"
            } catch is CancellationError { self.translationStates[bookID] = "已停止，已完成的译文已保留。" }
            catch { self.translationStates[bookID] = error.localizedDescription }
        }
    }
    private func validateTranslation(bookID: UUID, provider: AIProvider?, storage: LibraryStore, library: LibraryModel) throws {
        try Task.checkCancellation()
        guard !library.maintenance, library.store === storage, library.books.contains(where: { $0.id == bookID && !$0.removed && $0.hasBody }) else { throw CancellationError() }
        guard settings.resolvedProvider(for: .translation) == provider else { throw MoReadError.invalid("翻译模型已变化，请重新开始。") }
    }
    private func translationProgress(bookID: UUID, done: Int, total: Int, library: LibraryModel) {
        translationStates[bookID] = "已完成 \(done) / \(total) 段"; library.recordsRevision = UUID()
    }
    private func translationReply(provider: AIProvider?, messages: [ChatMessage]) async throws -> String {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--simulate-translations") {
            try await Task.sleep(for: .seconds(ProcessInfo.processInfo.arguments.contains("--translations-slow") ? 8 : 0.2))
            if ProcessInfo.processInfo.arguments.contains("--translations-fail") { throw MoReadError.invalid("翻译服务暂不可用。") }
            return "本地译文：" + (messages.last?.content ?? "")
        }
        #endif
        guard var provider else { throw MoReadError.invalid("请先在模型分工中选择翻译模型。") }
        provider.maxTokens = min(12_000, provider.maxTokens)
        return try await ChatClient.complete(provider: provider, key: KeychainStore.read(provider.id), messages: messages, maximumBytes: 96_000)
    }
}

struct ParagraphTranslationView: View {
    let bookID: UUID
    let chapter: Int
    var range: NSRange? = nil
    var sourceRevision: String? = nil
    var currentPage = false
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var companion: CompanionModel
    @State private var source: Chapter?
    @State private var paragraphs: [EnglishParagraph] = []
    @State private var translations: [ParagraphTranslation] = []
    @State private var visible = true
    @State private var error: String?
    @State private var confirmReplace = false
    @State private var replacementRange: NSRange?
    private var busy: Bool { companion.translatingBooks.contains(bookID) }
    var body: some View {
        List {
            Section {
                ModelAssignmentPicker(task: .translation)
                if currentPage { Text("当前页包含 \(paragraphs.count) 个英文段落").font(.caption).accessibilityIdentifier("translations-paragraph-count") }
                Toggle("显示译文", isOn: Binding(get: { visible }, set: { value in
                    change { store, book in
                        _ = try library.modifyRecords(for: book) { $0.translationsVisible = value }
                        visible = value
                    }
                })).accessibilityIdentifier("translations-visible")
                Button(currentPage ? "翻译当前页" : range == nil ? "翻译当前章" : "翻译选中段落") { start(range, replace: false) }
                    .disabled(busy || paragraphs.isEmpty).accessibilityIdentifier("translations-start")
                if !translations.isEmpty {
                    Button("重新翻译已有段落") { replacementRange = range; confirmReplace = true }
                        .disabled(busy).accessibilityIdentifier("translations-replace")
                }
                if busy { Button("停止翻译") { companion.translationTasks[bookID]?.cancel() }.accessibilityIdentifier("translations-stop") }
                Text("当前范围已保存 \(translations.count) / \(paragraphs.count) 段").font(.caption).accessibilityIdentifier("translations-saved-count")
                if let status = companion.translationStates[bookID] { Text("本书翻译任务：" + status).font(.caption).accessibilityIdentifier("translations-status") }
                if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("translations-error") }
            } footer: { Text("翻译所选范围内的完整英文段落，已保存的译文直接复用。整章翻译会发送本章原文并按服务商规则计费，阅读进度保持不变。") }
            if paragraphs.isEmpty { Text("此处没有可翻译的英文段落。").foregroundStyle(.secondary) }
            ForEach(paragraphs) { paragraph in
                Section {
                    Text(paragraph.text).textSelection(.enabled).accessibilityIdentifier("translation-source-\(paragraph.start)")
                    if let row = translations.first(where: { $0.start == paragraph.start }) {
                        if visible && !row.hidden { Text(row.chinese).foregroundStyle(.secondary).textSelection(.enabled).accessibilityIdentifier("translation-text-\(row.start)") }
                        Button(!visible || row.hidden ? "显示本段译文" : "隐藏本段译文") {
                            change { store, book in
                                let hidden = visible ? !row.hidden : false
                                try store.setHidden(hidden, translation: row, chapter: chapter)
                                if !hidden { _ = try library.modifyRecords(for: book) { $0.translationsVisible = true }; visible = true }
                            }
                        }.accessibilityIdentifier("translation-toggle-\(row.start)")
                        Button("重新翻译本段") { replacementRange = NSRange(location: row.start, length: row.end - row.start); confirmReplace = true }
                        Button("删除本段译文", role: .destructive) { change { store, _ in try store.delete(row, chapter: chapter) } }
                            .accessibilityIdentifier("translation-delete-\(row.start)")
                    } else { Text("尚未翻译").foregroundStyle(.secondary) }
                }.disabled(busy)
            }
        }.navigationTitle(currentPage ? "当前页对照" : range == nil ? "中英对照" : "本段对照")
            .task(id: library.recordsRevision) { load() }
            .confirmationDialog("重新翻译会再次调用当前模型；成功后替换原译文。", isPresented: $confirmReplace, titleVisibility: .visible) {
                Button("重新翻译") { start(replacementRange, replace: true) }
                Button("取消", role: .cancel) {}
            }
    }
    private func load() {
        do {
            guard let storage = library.store, let book = library.books.first(where: { $0.id == bookID && !$0.removed && $0.hasBody }) else { throw MoReadError.invalid("书籍已不可用。") }
            let current = try storage.chapter(chapter, in: book)
            guard sourceRevision == nil || current.revision == sourceRevision else { throw MoReadError.invalid("原文已变化，请重新选择段落。") }
            source = current; paragraphs = try EnglishParagraph.paragraphs(in: current.text, intersecting: range)
            let starts = Set(paragraphs.map(\.start))
            translations = try ParagraphTranslationStore(library: storage, bookID: bookID).load(chapter: chapter).filter { starts.contains($0.start) && $0.matches(current.text) }
            visible = try storage.records(for: book).translationsVisible ?? true; error = nil
        } catch { self.error = error.localizedDescription; source = nil; paragraphs = []; translations = [] }
    }
    private func start(_ range: NSRange?, replace: Bool) {
        guard let source else { return }
        companion.translate(bookID: bookID, source: source, range: range, replace: replace, library: library)
    }
    private func change(_ action: (ParagraphTranslationStore, Book) throws -> Void) {
        do {
            guard !library.maintenance, let storage = library.store, let book = library.books.first(where: { $0.id == bookID && !$0.removed && $0.hasBody }) else { throw MoReadError.invalid("书籍暂不可用。") }
            try action(ParagraphTranslationStore(library: storage, bookID: bookID), book); library.recordsRevision = UUID(); load()
        } catch { self.error = error.localizedDescription }
    }
}
