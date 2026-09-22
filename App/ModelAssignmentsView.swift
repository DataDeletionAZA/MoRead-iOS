import SwiftUI
import MoReadCore

struct ModelAssignmentsView: View {
    var body: some View {
        Form {
            Section {
                ModelAssignmentPicker(task: .chat)
                ModelAssignmentPicker(task: .batch)
            } header: { Text("对话与默认整理") } footer: {
                Text("批量模型供下方选择“使用默认模型”的任务共用。对话提要和长期记忆仍由各自开关控制，开启后会发送相关内容并按服务商规则计费。")
            }
            Section {
                ForEach([ModelTask.knowledge, .summary, .memory, .annotation, .coverQuery, .suggestion], id: \.self) { ModelAssignmentPicker(task: $0) }
            } header: { Text("各项任务") } footer: {
                Text("未分配批量模型时，章节、人物、段评、封面搜索词和建议回复沿用主对话模型。更换整理模型会停止对应的整理任务，已有结果保留；对话从下一条回复生效。")
            }
            Section {
                ModelAssignmentPicker(task: .image)
                NavigationLink("绘图接口与参数") { ImageGenerationSettingsView() }
            } header: { Text("绘图") } footer: {
                Text("独立绘图配置优先。也可在绘图设置中选择使用这里分配的地址、模型和密钥，并单独选择图片接口及参数。请选择支持绘图的模型。")
            }
            Section("检索与听书") {
                NavigationLink("向量服务商与模型") { VectorMemoryView() }
                NavigationLink("原文相关性排序") { RerankSettingsView() }
                NavigationLink("云端声音与缓存") { CloudSpeechView() }
            }
            Section { NavigationLink("管理 AI 服务商") { AISettingsView() } }
        }.navigationTitle("模型分工").navigationBarTitleDisplayMode(.inline)
    }
}

struct ModelAssignmentPicker: View {
    let task: ModelTask
    var title: String? = nil
    var identifier: String? = nil
    @EnvironmentObject private var companion: CompanionModel
    private var selected: UUID? { companion.settings.assignedProvider(for: task) }
    private var current: AIProvider? { companion.settings.resolvedProvider(for: task) }
    private var effectiveLabel: String? { task == .image ? companion.settings.imageConnection?.label : current.map { $0.name + " · " + $0.model } }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(title ?? task.label, selection: Binding(get: { selected }, set: { id in companion.perform { try companion.assignProvider(id, to: task) } })) {
                Text(task == .chat || task == .batch || task == .image ? "未分配" : "使用默认模型").tag(nil as UUID?)
                if let selected, !companion.settings.providers.contains(where: { $0.id == selected }) {
                    Text("已分配模型不可用").tag(Optional(selected))
                }
                ForEach(companion.settings.providers) { Text($0.name + " · " + $0.model).tag(Optional($0.id)) }
            }.accessibilityIdentifier(identifier ?? "model-role-" + task.rawValue)
            Text(effectiveLabel.map { "实际使用：" + $0 } ?? "尚无可用模型")
                .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("model-effective-" + task.rawValue)
        }
    }
}

extension CompanionModel {
    func assignProvider(_ id: UUID?, to task: ModelTask) throws {
        var next = settings; try next.assignProvider(id, to: task)
        try saveModelSettings(next)
    }
    func saveModelSettings(_ next: CompanionSettings) throws {
        guard let store else { throw MoReadError.invalid("伴读设置尚未打开。") }
        let previous = settings
        try store.save(next); settings = next
        if previous.imageConnection != next.imageConnection || previous.imageGeneration?.companionEnabled != next.imageGeneration?.companionEnabled { stopReply() }
        if previous.resolvedProvider(for: .knowledge) != next.resolvedProvider(for: .knowledge) { for job in knowledgeTasks.values { job.cancel() } }
        if previous.resolvedProvider(for: .summary) != next.resolvedProvider(for: .summary) { summaryTask?.cancel() }
        if previous.resolvedProvider(for: .memory) != next.resolvedProvider(for: .memory) { personaMemoryTask?.cancel() }
        if previous.resolvedProvider(for: .annotation) != next.resolvedProvider(for: .annotation) { stopAnnotations() }
        if next.suggestionRepliesEnabled == false || previous.resolvedProvider(for: .suggestion) != next.resolvedProvider(for: .suggestion) { dismissSuggestions() }
    }
    #if DEBUG
    var simulatedModelRoles: Bool { ProcessInfo.processInfo.arguments.contains("--ui-testing") && ProcessInfo.processInfo.arguments.contains("--simulate-model-roles") }
    #endif
}
