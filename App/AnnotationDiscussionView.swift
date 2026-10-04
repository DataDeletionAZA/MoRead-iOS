import SwiftUI
import MoReadCore

@MainActor struct AnnotationDiscussionView: View {
    let bookID: UUID
    let annotationID: UUID
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var companion: CompanionModel
    @AppStorage("discussion.character") private var remembered = ""
    @State private var annotation: Annotation?
    @State private var draft = ""
    @FocusState private var drafting: Bool
    @State private var invite = false
    @State private var characterID: UUID?
    @State private var streaming = ""
    @State private var activity: String?
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var requestID = UUID()
    @State private var snapshot: AnnotationDiscussion?
    private var book: Book? { library.books.first { $0.id == bookID } }
    private var character: CharacterCard? { companion.characters.first { $0.id == characterID } }
    private var provider: AIProvider? { companion.settings.resolvedProvider(for: .chat) }
    private var identity: ChatIdentity { companion.settings.currentIdentity }
    private var replies: [AnnotationReply] { (annotation?.replies ?? []).filter { $0.visible(in: library.books) } }
    private var shareText: String {
        guard let annotation else { return "" }
        let quote = "> " + annotation.passage.text.replacingOccurrences(of: "\n", with: "\n> ")
        let opening = annotation.authorLabel + "：" + annotation.note
        let thread = replies.map { $0.author + "：" + $0.text }.joined(separator: "\n\n")
        return [quote, opening, thread].joined(separator: "\n\n")
    }
    var body: some View {
        Form {
            if let annotation {
                Section("划线原文") { Text(annotation.passage.text).textSelection(.enabled) }
                Section(annotation.authorLabel) {
                    Text(annotation.note.isEmpty ? "尚未写下想法" : annotation.note).textSelection(.enabled).accessibilityIdentifier("discussion-opening")
                }
                ForEach(replies) { reply in
                    Section(reply.author) {
                        Text(reply.text).textSelection(.enabled).accessibilityIdentifier("discussion-reply-" + reply.id.uuidString)
                            .swipeActions { Button("删除发言", role: .destructive) { remove(reply) }.disabled(task != nil) }
                        Text(reply.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if task != nil {
                    Section(character?.name ?? "角色") {
                        Text(streaming.isEmpty ? activity ?? "正在思考…" : streaming).accessibilityIdentifier("discussion-streaming")
                        if let activity, !streaming.isEmpty { Text(activity).font(.caption).foregroundStyle(.secondary) }
                        Button("停止生成") { stop() }.accessibilityIdentifier("discussion-stop")
                    }
                }
                Section("接着聊") {
                    TextEditor(text: $draft).focused($drafting).frame(minHeight: 100).accessibilityIdentifier("discussion-draft")
                    Toggle("邀请角色回应", isOn: $invite).accessibilityIdentifier("discussion-invite")
                    if invite {
                        Picker("回应角色", selection: $characterID) {
                            Text("请选择角色").tag(UUID?.none)
                            ForEach(companion.characters) { Text($0.name).tag(Optional($0.id)) }
                        }
                        Text(provider.map { $0.name + " · " + $0.model } ?? "请在设置中选择聊天模型").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("发送") { send() }.disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (!invite || character == nil)).accessibilityIdentifier("discussion-send")
                }.disabled(task != nil)
            } else { ContentUnavailableView("这条批注暂不可用", systemImage: "text.bubble") }
        }.navigationTitle("批注讨论").disabled(library.maintenance).scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                if let error {
                    Text(error).font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding()
                        .background(.regularMaterial).accessibilityIdentifier("discussion-error")
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("收起键盘") { drafting = false }.accessibilityIdentifier("discussion-keyboard-done") }
                ToolbarItem(placement: .primaryAction) { ShareLink("分享讨论", item: shareText).disabled(annotation == nil) }
            }
            .task(id: library.recordsRevision) { reload() }
            .onAppear {
                if characterID == nil { characterID = companion.characters.first { $0.id.uuidString == remembered }?.id ?? companion.settings.selectedCharacter ?? companion.characters.first?.id }
                reload()
            }
            .onDisappear { stop() }
            .onChange(of: characterID) { _, value in if let value { remembered = value.uuidString } }
            .onChange(of: library.books) { _, _ in reload() }
            .onChange(of: scenePhase) { _, phase in if phase == .background { stop() } }
            .onChange(of: provider) { _, _ in invalidate("模型已变化，请重新发送。") }
            .onChange(of: character) { _, _ in invalidate("角色已变化，请重新发送。") }
            .onChange(of: identity) { _, _ in invalidate("身份已变化，请重新发送。") }
            .onChange(of: library.maintenance) { _, active in if active { stop(); annotation = nil } else { reload() } }
    }
    private func current() throws -> (Book, Annotation, BookRecords) {
        guard !library.maintenance, let book, let store = library.store else { throw MoReadError.invalid("书籍暂不可用。") }
        let records = try store.records(for: book)
        guard let entry = ReadingReview.entries(books: [book], records: [book.id: records]).first(where: {
            if case .annotation(let value) = $0.content { return value.id == annotationID }; return false
        }), case .annotation(let annotation) = entry.content else { throw MoReadError.invalid("批注已删除或超出当前已读范围。") }
        return (book, annotation, records)
    }
    private func reload() {
        do {
            let (book, value, records) = try current()
            if let snapshot { try snapshot.validate(book: book, records: records, books: library.books) }
            annotation = value
        } catch { stop(); annotation = nil; self.error = error.localizedDescription }
    }
    private func invalidate(_ message: String) { if task != nil { stop(); error = message } }
    private func stop() { requestID = UUID(); task?.cancel(); task = nil; snapshot = nil; streaming = ""; activity = nil }
    private func remove(_ reply: AnnotationReply) {
        do {
            let (book, value, _) = try current()
            try library.modifyRecords(for: book) { try AnnotationDiscussion.remove(reply, from: value, book: book, records: &$0) }
        } catch { self.error = error.localizedDescription }
    }
    private func send() {
        guard task == nil else { return }
        do {
            error = nil; drafting = false
            if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let (book, original, _) = try current()
                let reply = AnnotationReply(text: draft, author: identity.name, identity: identity)
                try library.modifyRecords(for: book) { try AnnotationDiscussion.append(reply, to: original, book: book, records: &$0) }
                draft = ""; reload()
            }
            guard invite else { return }
            guard let character, let store = library.store else { throw MoReadError.invalid("请选择回应角色。") }
            library.flush()
            let (book, annotation, records) = try current()
            let value = try AnnotationDiscussion(book: book, annotation: annotation, chapter: store.chapter(annotation.passage.chapter, in: book), books: library.books, records: records)
            let selectedProvider = provider, selectedIdentity = identity, id = UUID()
            requestID = id; snapshot = value; streaming = ""; activity = nil
            task = Task {
                defer { if requestID == id { task = nil; snapshot = nil; activity = nil; streaming = "" } }
                do {
                    let extraScopes = try await respond(value, character: character, identity: selectedIdentity, provider: selectedProvider, id: id)
                    try Task.checkCancellation()
                    guard requestID == id else { return }
                    let (currentBook, original, currentRecords) = try current()
                    try value.validate(book: currentBook, records: currentRecords, books: library.books)
                    guard extraScopes.allSatisfy({ $0.isValid(in: library.books) }) else { throw MoReadError.invalid("讨论来源已变化，请重试。") }
                    var reply = AnnotationReply(text: streaming, author: character.name, identity: selectedIdentity)
                    reply.characterID = character.id; reply.scopes = AnnotationDiscussion.mergedScopes(value.scopes + extraScopes)
                    try reply.validate(); snapshot = nil
                    try library.modifyRecords(for: currentBook) { try AnnotationDiscussion.append(reply, to: original, book: currentBook, records: &$0) }
                    reload()
                } catch is CancellationError {} catch { if requestID == id { self.error = error.localizedDescription } }
            }
        } catch { self.error = error.localizedDescription }
    }
    private func respond(_ value: AnnotationDiscussion, character: CharacterCard, identity: ChatIdentity, provider selected: AIProvider?, id: UUID) async throws -> [MemoryBookScope] {
        let settings = companion.settings
        var scopes: [MemoryBookScope] = []
        func validate() throws {
            try Task.checkCancellation()
            guard requestID == id, provider == selected, self.character == character, self.identity == identity,
                  companion.settings.toolsEnabled == settings.toolsEnabled, companion.settings.personaMemory == settings.personaMemory else { throw CancellationError() }
            let (book, _, records) = try current()
            try value.validate(book: book, records: records, books: library.books)
            guard scopes.allSatisfy({ $0.isValid(in: library.books) }) else { throw MoReadError.invalid("讨论来源已变化。") }
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--simulate-discussion") {
            try validate(); streaming = "我觉得书店里的灯光，像在等一个愿意停下来的人。"
            let text = value.replies.last?.text ?? value.annotation.note
            try await Task.sleep(for: .seconds(text.contains("slow") ? 8 : 0.3)); try validate()
            if text.contains("fail") { throw MoReadError.invalid("本地模拟：讨论服务暂不可用。") }
            return []
        }
        #endif
        guard var selected else { throw MoReadError.invalid("请先在设置中选择聊天模型。") }
        let key = try await KeychainStore.readAsync(selected.id); try validate()
        selected.maxTokens = min(selected.maxTokens, 4096)
        let memory = settings.personaMemory ?? PersonaMemorySettings()
        let allowed = Array(AnnotationDiscussion.readTools.intersection(character.enabledTools ?? Array(AnnotationDiscussion.readTools))).sorted()
        let tools = settings.toolsEnabled == false ? [] : try ReaderTools.specs(currentBook: bookID, memory: memory.enabled && !memory.disabledCharacters.contains(character.id), enabled: allowed)
        let messages = value.messages(character: character, identity: identity)
        try await ChatToolLoop.run(tools: tools, maximumRounds: 5, stream: { exchanges in
            try await ChatClient.turn(provider: selected, key: key, messages: messages, tools: tools, exchanges: exchanges) { delta in
                await MainActor.run {
                    do { try validate(); streaming += TextBoundary.prefix(delta, end: max(0, 5000 - streaming.utf16.count)); activity = nil }
                    catch { if requestID == id { invalidate(error.localizedDescription) } }
                }
            }
        }, execute: { call in
            try validate()
            if call.name == "recall_memory" {
                let conversation = Conversation(title: "批注讨论", bookID: bookID, characterID: character.id)
                return try await companion.recallPersonaMemory(query: ReaderTools.query(call.object()), conversation: conversation, identity: identity, library: library) { scopes += $0 }
            }
            guard let root = library.store?.root else { throw CancellationError() }
            let output: ReaderToolOutput
            if call.name == "search_book" {
                _ = try ReaderTools.book(arguments: call.object(), currentBook: bookID, books: [value.book])
                output = try await companion.searchBookForTool(call, book: value.book, library: library)
            }
            else {
                let work = Task.detached { try ReaderTools.execute(call, currentBook: value.book.id, books: [value.book], store: LibraryStore(root: root)) }
                output = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            }
            return output.text + output.passages.map { "\n第\($0.chapter + 1)章：\($0.text)" }.joined()
        }, validate: { try validate() }, report: { event in
            if case .started(let call) = event { activity = ReaderTools.titles[call.name] ?? "查询资料…" }
        })
        return scopes
    }
}
