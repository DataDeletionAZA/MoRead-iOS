import SwiftUI
import MoReadCore

@MainActor struct TextCleanupGenerator: View {
    let bookID: UUID
    let listeningOnly: Bool
    let save: (TextReplacementRule) -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var companion: CompanionModel
    @State private var requirement = ""
    @State private var wholeBook = false
    @State private var sample: TextCleanupSample?
    @State private var draft: TextReplacementRule?
    @State private var task: Task<Void, Never>?
    @State private var requestID = UUID()
    @State private var confirmation = false
    @State private var error: String?
    private var provider: AIProvider? { companion.settings.resolvedProvider(for: .chat) }
    private var book: Book? { library.books.first { $0.id == bookID } }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("例如：删除每章末尾的加群广告", text: $requirement, axis: .vertical)
                        .lineLimit(3...8).accessibilityIdentifier("cleanup-ai-requirement")
                    ModelAssignmentPicker(task: .chat, title: "生成模型")
                } header: { Text("清理需求") } footer: { Text(listeningOnly ? "生成听书专用规则，只改变朗读文字。" : "生成可编辑的草稿。保存规则后，仍需返回正文清理页预览和确认应用。") }
                Section {
                    Picker("取样范围", selection: $wholeBook) {
                        Text("已读范围").tag(false); Text("全书").tag(true)
                    }.pickerStyle(.segmented).accessibilityIdentifier("cleanup-ai-scope")
                    Button("预览取样") { prepare() }.accessibilityIdentifier("cleanup-ai-preview")
                    if let sample {
                        Text("已取样 \(sample.sampledChapters) / \(sample.eligibleChapters) 章 · \(sample.text.utf16.count) 字符")
                            .accessibilityIdentifier("cleanup-ai-summary")
                        DisclosureGroup("查看将发送的片段") { Text(sample.text).font(.caption).textSelection(.enabled) }
                        Button("生成规则草稿") { confirmation = true }
                            .disabled(requirement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("cleanup-ai-generate")
                    }
                } footer: { Text("每章最多取 4000 字符，合计最多 72000 字符。超长书籍会均匀选取最多 600 章。全书范围包含尚未读到的内容。预览在本机完成。") }
                if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("cleanup-ai-error") }
            }
            .disabled(task != nil || library.maintenance)
            .navigationTitle("AI 生成清理规则").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { stop(); dismiss() } } }
            .safeAreaInset(edge: .bottom) {
                if task != nil { HStack { ProgressView(); Text("正在处理…"); Spacer(); Button("停止") { stop() }.accessibilityIdentifier("cleanup-ai-stop") }.padding().background(.regularMaterial) }
            }
            .alert("发送片段并生成草稿？", isPresented: $confirmation) {
                Button("取消", role: .cancel) {}
                Button("确认生成") { generate() }
            } message: {
                Text("将把需求和上方取样发送给 \(provider.map { $0.name + " · " + $0.model } ?? "所选模型")，发起一次 AI 请求并按服务商规则计费。\(wholeBook ? "取样包含未读内容，生成的规则也可能涉及后文。" : "取样仅限已读范围。")")
            }
            .sheet(item: $draft) { value in
                TextReplacementEditor(rule: value) { rule in save(rule); dismiss() }
            }
            .onDisappear { stop() }
            .onChange(of: wholeBook) { _, _ in stop(); sample = nil }
            .onChange(of: provider) { _, _ in stop() }
            .onChange(of: library.maintenance) { _, active in if active { stop(); sample = nil } }
            .onChange(of: book) { _, value in
                guard let sample else { return }
                guard let value, (try? sample.validate(in: value)) != nil else { stop(); self.sample = nil; return }
            }
        }
    }
    private func stop() { requestID = UUID(); task?.cancel(); task = nil }
    private func current(_ sample: TextCleanupSample, provider: AIProvider?) throws {
        try Task.checkCancellation()
        guard !library.maintenance, self.provider == provider, let book, let store = library.store else { throw CancellationError() }
        try sample.validate(in: book); try sample.validate(in: store.book(bookID))
    }
    private func prepare() {
        guard task == nil, !library.maintenance, let root = library.store?.root else { return }
        library.flush(); error = nil; sample = nil
        let id = UUID(), bookID = bookID, wholeBook = wholeBook
        requestID = id
        task = Task {
            defer { if requestID == id { task = nil } }
            do {
                let worker = Task.detached { try LibraryStore(root: root).textCleanupSample(bookID: bookID, wholeBook: wholeBook) }
                let value = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard requestID == id else { return }
                try current(value, provider: provider); sample = value
            } catch is CancellationError {} catch { if requestID == id { self.error = error.localizedDescription } }
        }
    }
    private func generate() {
        guard task == nil, let sample else { return }
        let id = UUID(), selected = provider, requirement = requirement
        requestID = id; error = nil
        task = Task {
            defer { if requestID == id { task = nil } }
            do {
                try current(sample, provider: selected)
                let messages = try sample.messages(requirement: requirement, listeningOnly: listeningOnly)
                let raw: String
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--simulate-cleanup-rule") {
                    try await Task.sleep(for: .seconds(requirement.contains("slow") ? 8 : 0.3))
                    if requirement.contains("fail") { throw MoReadError.invalid("清理规则服务暂不可用。") }
                    raw = requirement.contains("invalid") ? "{\"pattern\":\"[\"}" : "{\"name\":\"AI 清理规则\",\"pattern\":\"rain\",\"replacement\":\"sunrise\",\"ignoreCase\":false}"
                } else { raw = try await reply(selected, messages: messages, sample: sample) }
                #else
                raw = try await reply(selected, messages: messages, sample: sample)
                #endif
                try current(sample, provider: selected)
                let value = try TextCleanupProposal.parse(raw, listeningOnly: listeningOnly)
                guard requestID == id else { return }
                draft = value
            } catch is CancellationError {} catch { if requestID == id { self.error = error.localizedDescription } }
        }
    }
    private func reply(_ selected: AIProvider?, messages: [ChatMessage], sample: TextCleanupSample) async throws -> String {
        guard var selected else { throw MoReadError.invalid("请先选择生成模型，可在设置中添加 AI 服务商。") }
        let key = try await KeychainStore.readAsync(selected.id)
        try current(sample, provider: selected)
        selected.maxTokens = min(selected.maxTokens, 6000)
        return try await ChatClient.complete(provider: selected, key: key, messages: messages, maximumBytes: 64_000)
    }
}
