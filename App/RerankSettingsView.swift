import SwiftUI
import MoReadCore

struct RerankSettingsView: View {
    @EnvironmentObject private var companion: CompanionModel
    private var policy: RerankSettings { companion.settings.rerank ?? RerankSettings() }
    private func field<T>(_ key: WritableKeyPath<RerankSettings, T>) -> Binding<T> {
        Binding(get: { policy[keyPath: key] }, set: { value in
            var policy = policy; policy[keyPath: key] = value
            companion.settings.rerank = policy; companion.saveSettings()
        })
    }
    var body: some View {
        Form {
            Section {
                Toggle("按问题重新排序原文", isOn: field(\.enabled)).accessibilityIdentifier("rerank-enabled")
                Picker("重排服务商", selection: field(\.providerID)) {
                    Text("请选择").tag(UUID?.none)
                    ForEach(companion.settings.providers) { Text($0.name).tag(Optional($0.id)) }
                }
                TextField("重排模型名称", text: field(\.model)).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("rerank-model")
                TextField("接口路径", text: field(\.endpoint)).textInputAutocapitalization(.never).autocorrectionDisabled()
                NavigationLink("管理 AI 服务商") { AISettingsView() }
            } footer: {
                Text("选择支持 Cohere / Jina 兼容重排接口的服务商，填写它提供的重排模型。接口路径接在服务商地址后，通常为 rerank。它会比较问题与已找到的原文，把更相关的段落放在前面。")
            }
            Section {
                Text("开启后，每次符合条件的伴读请求会将问题和最多 24 段已读原文发送给重排服务商，可能产生 API 费用。每段最多 800 个字符，总共不超过 12000；不发送整本书。")
                Text("手动选中的原文保持在首位。服务暂时不可用时继续使用原来的检索顺序，并在回复下说明。")
            }
        }.navigationTitle("原文相关性排序").disabled(companion.busy)
    }
}

extension CompanionModel {
    #if DEBUG
    var simulatedRerank: Bool { ProcessInfo.processInfo.arguments.contains("--ui-testing") && ProcessInfo.processInfo.arguments.contains("--simulate-rerank") }
    #endif
    func rerankContext(_ context: inout CompanionContext, query: String, selection: SourcePassage?, library: LibraryModel) async throws -> String? {
        let policy = settings.rerank ?? RerankSettings()
        guard policy.enabled, context.rerankPassages.filter({ $0.id != selection?.id }).count >= 2 else { return nil }
        try Task.checkCancellation(); try context.validateSources(books: library.books)
        do {
            guard var provider = settings.providers.first(where: { $0.id == policy.providerID }) else { throw MoReadError.invalid("请选择重排服务商。") }
            provider.model = policy.model.trimmingCharacters(in: .whitespacesAndNewlines)
            let key: String
            #if DEBUG
            key = simulatedRerank ? "local-test" : try KeychainStore.read(provider.id)
            #else
            key = try KeychainStore.read(provider.id)
            #endif
            memoryStatus = "正在比较原文与问题…"
            defer { memoryStatus = nil }
            let ordered = try await RerankClient.reorder(query: query, passages: context.rerankPassages, pinnedID: selection?.id) { question, documents in
                #if DEBUG
                if self.simulatedRerank {
                    _ = try RerankClient.request(provider: provider, key: key, endpoint: policy.endpoint, query: question, documents: documents)
                    try await Task.sleep(for: .milliseconds(100))
                    if query.contains("unavailable") { throw MoReadError.invalid("本地模拟：重排不可用。") }
                    return Array(documents.indices.reversed())
                }
                #endif
                return try await RerankClient.rank(provider: provider, key: key, endpoint: policy.endpoint, query: question, documents: documents)
            }
            try Task.checkCancellation(); try context.validateSources(books: library.books)
            guard (settings.rerank ?? RerankSettings()) == policy,
                  var current = settings.providers.first(where: { $0.id == policy.providerID }) else { throw CancellationError() }
            current.model = policy.model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard current == provider else { throw CancellationError() }
            guard let root = library.store?.root else { throw CancellationError() }
            let snapshot = context, books = library.books
            let work = Task.detached { var value = snapshot; try value.applyRanking(ordered, books: books, store: LibraryStore(root: root)); return value }
            let updated = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            try updated.validateSources(books: library.books); try Task.checkCancellation()
            guard (settings.rerank ?? RerankSettings()) == policy else { throw CancellationError() }
            context = updated
            return "已按问题的相关性排列原文。"
        } catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation(); try context.validateSources(books: library.books)
            return "相关性排序暂不可用，已使用原来的原文检索顺序。"
        }
    }
}
