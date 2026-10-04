import SwiftUI
import MoReadCore

@MainActor struct ReviewComposer: View {
    let entries: [ReadingReviewEntry]
    let mode: ReviewComposition.Mode
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var companion: CompanionModel
    @Environment(\.dismiss) private var dismiss
    @State private var bookID: UUID?
    @State private var characterID: UUID?
    @State private var excluded = Set<String>()
    @State private var instruction = ""
    @State private var snapshot: ReviewComposition?
    @State private var author: CharacterCard?
    @State private var title = ""
    @State private var content = ""
    @State private var task: Task<Void, Never>?
    @State private var requestID = UUID()
    @State private var error: String?
    @State private var confirmation = false
    @State private var discard = false
    @State private var choosingAgain = false
    @State private var saved = false
    private var provider: AIProvider? { companion.settings.resolvedProvider(for: .chat) }
    private var character: CharacterCard? { companion.characters.first { $0.id == characterID } }
    private var book: Book? { library.books.first { $0.id == bookID } }
    private var books: [Book] { var seen = Set<UUID>(); return entries.compactMap { seen.insert($0.book.id).inserted ? $0.book : nil } }
    private var candidates: [ReadingReviewEntry] { bookID.map { ReviewComposition.candidates(entries, bookID: $0) } ?? [] }
    private var chosen: [ReadingReviewEntry] { candidates.filter { !excluded.contains($0.id) } }
    var body: some View {
        NavigationStack {
            Form {
                if let snapshot {
                    Section("草稿 · \(snapshot.sources.count) 条素材") {
                        TextField("标题", text: $title).accessibilityIdentifier("review-draft-title")
                        TextEditor(text: $content).frame(minHeight: 260).accessibilityIdentifier("review-draft-content")
                        Text("保存为新笔记，并附上素材出处。").font(.caption).foregroundStyle(.secondary)
                    }.disabled(task != nil)
                    DisclosureGroup("查看所用素材") { Text(snapshot.sourceText).font(.callout).textSelection(.enabled) }
                    if task == nil {
                        Button("重新生成") { confirmation = true }.accessibilityIdentifier("review-regenerate")
                        Button("重新选择素材") { choosingAgain = true }
                        if !content.isEmpty { ShareLink("分享草稿", item: "# \(title)\n\n\(content)") }
                    }
                } else {
                    Section {
                        Picker("书籍", selection: $bookID) { ForEach(books) { Text($0.title).tag(Optional($0.id)) } }.accessibilityIdentifier("review-compose-book")
                        Picker("伴读角色", selection: $characterID) {
                            Text("请选择角色").tag(UUID?.none)
                            ForEach(companion.characters) { Text($0.name).tag(Optional($0.id)) }
                        }.accessibilityIdentifier("review-compose-character")
                        ModelAssignmentPicker(task: .chat, title: "生成模型")
                        TextField("例如：提出另一种解释，保留我的个人感受", text: $instruction, axis: .vertical).lineLimit(3...8).accessibilityIdentifier("review-compose-instruction")
                    }
                    Section {
                        ForEach(candidates) { entry in
                            Toggle(isOn: Binding(get: { !excluded.contains(entry.id) }, set: { if $0 { excluded.remove(entry.id) } else { excluded.insert(entry.id) } })) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(entry.author + " · " + entry.title).font(.headline)
                                    if !entry.quote.isEmpty { Text(entry.quote) }
                                    if !entry.body.isEmpty { Text(entry.body).foregroundStyle(.secondary) }
                                }
                            }.accessibilityIdentifier("review-material-" + entry.title)
                        }
                        if candidates.isEmpty { Text("当前范围没有可选素材，请返回调整筛选条件。").foregroundStyle(.secondary) }
                    } header: { Text("已选 \(chosen.count) 条完整素材") }
                    footer: { Text("按当前排序取同一本书的最多 20 条完整记录，总计最多 24000 字符。可取消勾选，或返回回顾页调整筛选条件。") }
                }
                if let error { Section { Text(error).foregroundStyle(.secondary).accessibilityIdentifier("review-compose-error") } }
            }.disabled(library.maintenance || saved)
                .navigationTitle(mode.rawValue).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { if snapshot != nil || !instruction.isEmpty { discard = true } else { dismiss() } } } }
                .safeAreaInset(edge: .bottom) {
                    HStack {
                        if task != nil { ProgressView(); Text("正在生成草稿…"); Spacer(); Button("停止") { stop(); error = "已停止，可以编辑已有草稿。" }.accessibilityIdentifier("review-compose-stop") }
                        else if snapshot != nil { Button("保存为新笔记") { save() }.buttonStyle(.borderedProminent).disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saved).accessibilityIdentifier("review-compose-save") }
                        else { Button("生成草稿") { confirmation = true }.buttonStyle(.borderedProminent).disabled(chosen.isEmpty || character == nil).accessibilityIdentifier("review-compose-generate") }
                    }.frame(maxWidth: .infinity).padding().background(.regularMaterial).disabled(library.maintenance)
                }
                .alert("发送素材并生成草稿？", isPresented: $confirmation) {
                    Button("取消", role: .cancel) {}
                    Button("确认生成") { generate() }
                } message: { Text("将把所选素材、要求和角色设定发送给 \(provider.map { $0.name + " · " + $0.model } ?? "所选模型")，按服务商规则计费。重新生成会替换当前草稿。") }
                .confirmationDialog("放弃当前草稿并关闭？", isPresented: $discard, titleVisibility: .visible) {
                    Button("放弃并关闭", role: .destructive) { stop(); dismiss() }
                }
                .confirmationDialog("放弃草稿并重新选择素材？", isPresented: $choosingAgain, titleVisibility: .visible) {
                    Button("重新选择", role: .destructive) { stop(); snapshot = nil; author = nil; title = ""; content = ""; error = nil }
                }
                .interactiveDismissDisabled(snapshot != nil || !instruction.isEmpty || task != nil)
                .onAppear { if bookID == nil { bookID = entries.first?.book.id }; if characterID == nil { characterID = companion.settings.selectedCharacter ?? companion.characters.first?.id } }
                .onDisappear { stop() }
                .onChange(of: bookID) { _, _ in excluded = [] }
                .onChange(of: provider) { _, _ in if task != nil { stop(); error = "模型已变化，已停止生成。" } }
                .onChange(of: character) { _, _ in if task != nil { stop(); error = "角色已变化，已停止生成。" } }
                .onChange(of: library.recordsRevision) { _, _ in validateDraft() }
                .onChange(of: book) { _, _ in validateDraft() }
                .onChange(of: library.maintenance) { _, active in if active { stop(); error = "书库正在维护，请稍后重新核对素材。" } }
        }
    }
    private func stop() { requestID = UUID(); task?.cancel(); task = nil }
    private func current(_ value: ReviewComposition) throws -> (Book, BookRecords) {
        guard !library.maintenance, let book = library.books.first(where: { $0.id == value.book.id }), let store = library.store else { throw MoReadError.invalid("书籍不可用，请重新选择素材。") }
        let records = try store.records(for: book)
        try value.validate(book: book, records: records)
        try value.validate(book: store.book(book.id), records: records)
        return (book, records)
    }
    private func validateDraft() {
        guard let snapshot else { return }
        do { _ = try current(snapshot) } catch { stop(); self.error = error.localizedDescription }
    }
    private func receive(_ delta: String, id: UUID) {
        guard requestID == id else { return }
        let remaining = ReviewComposition.maximumDraftLength - content.utf16.count
        if delta.utf16.count > remaining {
            content += TextBoundary.prefix(delta, end: remaining)
            stop(); error = "草稿已达到 32000 字符，已停止生成，可以编辑已有内容。"
        } else { content += delta }
    }
    private func generate() {
        guard task == nil, let selectedCharacter = character else { error = "请选择一个可用的伴读角色。"; return }
        do {
            let value = try snapshot ?? ReviewComposition(sources: chosen, mode: mode)
            library.flush(); _ = try current(value)
            let messages = try value.messages(character: selectedCharacter, identity: companion.settings.currentIdentity, instruction: instruction)
            let id = UUID(), selectedProvider = provider, requirement = instruction
            requestID = id; snapshot = value; author = selectedCharacter; title = value.defaultTitle; content = ""; error = nil
            task = Task {
                defer { if requestID == id { task = nil } }
                do {
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--simulate-review-composition") {
                        receive("## 重新看这束光\n\n这是角色补充的观点，素材 [1] 让人想到等待。", id: id)
                        try await Task.sleep(for: .seconds(requirement.contains("slow") ? 8 : 0.3))
                        if requirement.contains("fail") { throw MoReadError.invalid("点评服务暂不可用。") }
                        receive("\n\n你会怎样理解这份等待？", id: id)
                    } else { try await reply(selectedProvider, messages: messages, snapshot: value, id: id) }
                    #else
                    try await reply(selectedProvider, messages: messages, snapshot: value, id: id)
                    #endif
                    try Task.checkCancellation(); guard requestID == id else { return }
                    _ = try current(value)
                    guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MoReadError.invalid("服务商没有返回正文，请重试。") }
                } catch is CancellationError {} catch { if requestID == id { self.error = error.localizedDescription } }
            }
        } catch { self.error = error.localizedDescription }
    }
    private func reply(_ selected: AIProvider?, messages: [ChatMessage], snapshot: ReviewComposition, id: UUID) async throws {
        guard var selected else { throw MoReadError.invalid("请先在设置中添加并选择 AI 模型。") }
        let key = try await KeychainStore.readAsync(selected.id)
        try Task.checkCancellation(); _ = try current(snapshot)
        guard requestID == id, provider == selected else { throw CancellationError() }
        selected.maxTokens = min(selected.maxTokens, 16_000)
        try await ChatClient.stream(provider: selected, key: key, messages: messages) { delta in await receive(delta, id: id) }
    }
    private func save() {
        guard task == nil, !saved, let snapshot, let author else { return }
        do {
            guard companion.characters.contains(where: { $0.id == author.id }) else { throw MoReadError.invalid("这个角色已删除，请选择可用角色重新生成。") }
            let (book, records) = try current(snapshot)
            let note = try snapshot.note(title: title, content: content, character: author, current: book, records: records)
            try library.modifyRecords(for: book) { currentRecords in
                try snapshot.validate(book: book, records: currentRecords)
                if currentRecords.notes == nil { currentRecords.notes = [] }
                currentRecords.notes?.append(note)
            }
            saved = true; dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
