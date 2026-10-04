import SwiftUI
import MoReadCore

struct ChapterRuleAssistantView: View {
    let url: URL
    let encoding: String.Encoding?
    let apply: (ChapterRuleProposal) -> Void
    @StateObject private var model = ChapterRuleAssistantModel()
    @EnvironmentObject private var companion: CompanionModel
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ModelAssignmentPicker(task: .batch, title: "分章使用的批量整理模型").disabled(model.busy)
                } footer: {
                    Text("仅发送开头、中间与结尾附近的文字结构样本，文字内容会替换为占位符。建议规则会在本机检查全书，再交给你决定是否采用。")
                }
                if let proposal = model.proposal {
                    Section("建议规则") {
                        Text(proposal.name).font(.headline)
                        Text(proposal.reason)
                        Text(proposal.regex).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        LabeledContent("本地检查结果", value: "\(proposal.chapterCount) 章").accessibilityIdentifier("chapter-ai-result")
                    }
                    Section {
                        ForEach(Array(proposal.sampleTitles.enumerated()), id: \.offset) { _, title in Text(title) }
                    } header: { Text("部分章节标题") } footer: { Text("目录标题可能涉及后文。采用后可以在导入预览中逐章检查正文。") }
                }
                if let message = model.message { Text(message).foregroundStyle(.secondary).accessibilityIdentifier("chapter-ai-message") }
            }
            .navigationTitle("AI 辅助分章").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { model.stop(); dismiss() }.accessibilityIdentifier("chapter-ai-close") } }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    if model.busy {
                        HStack { ProgressView(); Text(model.activity); Spacer(); Button("停止") { model.stop() }.accessibilityIdentifier("chapter-ai-stop") }
                    } else {
                        if let proposal = model.proposal {
                            Button("采用并预览目录") { apply(proposal); dismiss() }.buttonStyle(.borderedProminent).accessibilityIdentifier("chapter-ai-apply")
                        }
                        Button(model.proposal == nil ? "请 AI 识别章节" : "重新尝试") {
                            model.start(url: url, encoding: encoding, provider: companion.settings.resolvedProvider(for: .batch))
                        }.accessibilityIdentifier("chapter-ai-start")
                    }
                }.frame(maxWidth: .infinity).padding().background(.regularMaterial)
            }
            .onDisappear { model.stop() }
            .onChange(of: phase) { _, value in if value != .active { model.stop() } }
            .onChange(of: companion.settings.resolvedProvider(for: .batch)) { _, _ in model.stop(); model.proposal = nil }
            .onChange(of: library.maintenance) { _, value in if value { model.stop(); dismiss() } }
        }
    }
}

@MainActor private final class ChapterRuleAssistantModel: ObservableObject {
    @Published var proposal: ChapterRuleProposal?
    @Published var busy = false
    @Published var activity = "正在准备结构样本…"
    @Published var message: String?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    func start(url: URL, encoding: String.Encoding?, provider: AIProvider?) {
        guard !busy else { return }
        generation = UUID(); let token = generation
        proposal = nil; message = nil; busy = true; activity = "正在准备结构样本…"
        task = Task {
            do {
                let reply: ChapterRuleAssistant.Reply
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--simulate-chapter-rule") {
                    reply = { messages in
                        try await Task.sleep(for: .milliseconds(ProcessInfo.processInfo.arguments.contains("--chapter-rule-slow") ? 30_000 : 300))
                        if ProcessInfo.processInfo.arguments.contains("--chapter-rule-fail") { throw MoReadError.invalid("分章服务暂不可用，请稍后重试。") }
                        return messages.count == 2 ? #"{"name":"尝试规则","regex":"^不存在$","reason":"尝试识别标题"}"# : #"{"name":"中文章节标题","regex":"^第[一二三四五六七八九十0-9]+章.*$","reason":"章节以序号和章字开头。"}"#
                    }
                } else { reply = try await Self.reply(provider: provider) }
                #else
                reply = try await Self.reply(provider: provider)
                #endif
                try Task.checkCancellation()
                let worker = Task.detached(priority: .userInitiated) {
                    let text = try TextImporter.decode(TextImporter.read(url), encoding: encoding)
                    try Task.checkCancellation()
                    return try await ChapterRuleAssistant.propose(text: text, reply: reply, progress: { attempt in
                        await self.progress(attempt, token: token)
                    })
                }
                let value = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard token == generation else { return }
                proposal = value; message = "已通过本地分章检查，请核对标题和正文。"
            } catch is CancellationError {} catch { if token == generation { message = error.localizedDescription } }
            if token == generation { busy = false; task = nil }
        }
    }
    private func progress(_ attempt: Int, token: UUID) { if token == generation { activity = "正在尝试第 \(attempt) / 3 轮…" } }
    private static func reply(provider: AIProvider?) async throws -> ChapterRuleAssistant.Reply {
        guard var provider else { throw MoReadError.invalid("请先在设置中添加 AI 服务商，并选择批量整理模型。") }
        provider.maxTokens = min(provider.maxTokens, 1200)
        let key = try await KeychainStore.readAsync(provider.id), selected = provider
        return { messages in try await ChatClient.complete(provider: selected, key: key, messages: messages, maximumBytes: 12000) }
    }
    func stop() {
        generation = UUID(); task?.cancel(); task = nil
        if busy { message = "已停止，可以重新尝试。" }
        busy = false
    }
}
