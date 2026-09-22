import SwiftUI
import MoReadCore

struct GlobalPromptView: View {
    @EnvironmentObject private var companion: CompanionModel
    @State private var editing: GlobalPromptPreset?
    private var presets: [GlobalPromptPreset] { companion.settings.resolvedGlobalPrompts }
    var body: some View {
        List {
            Section {
                Text("已启用 \(presets.filter(\.enabled).count) 个预设").font(.headline)
                Text("预设会随每次伴读对话发送给 AI。修改从下一条回复开始生效，聊天原文保持不变。").font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                ForEach(presets) { preset in
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: Binding(get: { presets.first { $0.id == preset.id }?.enabled ?? false }, set: { enabled in
                            companion.perform { var values = presets; if let index = values.firstIndex(where: { $0.id == preset.id }) { values[index].enabled = enabled }; try companion.saveGlobalPrompts(values) }
                        })) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(preset.name)
                                Text(preset.position.label + (preset.builtIn ? " · 内置" : " · 自定义")).font(.caption).foregroundStyle(.secondary)
                            }
                        }.accessibilityIdentifier("preset-toggle-" + preset.name)
                        Text(preset.prompt).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                        Button("编辑", systemImage: "pencil") { editing = preset }.buttonStyle(.borderless)
                            .accessibilityLabel("编辑" + preset.name).accessibilityIdentifier("preset-edit-" + preset.name)
                    }.padding(.vertical, 4)
                        .swipeActions { Button("删除", role: .destructive) { companion.perform { try companion.saveGlobalPrompts(presets.filter { $0.id != preset.id }) } } }
                }
                Button("添加自定义预设", systemImage: "plus") { editing = GlobalPromptPreset() }
            }
        }.navigationTitle("全局提示词预设").navigationBarTitleDisplayMode(.inline)
            .sheet(item: $editing) { GlobalPromptEditor(preset: $0) }
    }
}

private struct GlobalPromptEditor: View {
    @State var preset: GlobalPromptPreset
    @State private var error: String?
    @EnvironmentObject private var companion: CompanionModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("预设名称", text: $preset.name).accessibilityIdentifier("preset-name")
                    Toggle("启用这个预设", isOn: $preset.enabled)
                    Picker("添加位置", selection: $preset.position) {
                        ForEach(GlobalPromptPosition.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.accessibilityIdentifier("preset-position")
                } footer: { Text("系统提示词包含角色设定和阅读规则；用户消息是你这次发送的话。") }
                Section("提示词") {
                    TextEditor(text: $preset.prompt).frame(minHeight: 180).accessibilityIdentifier("preset-content")
                    Text("\(preset.prompt.utf16.count) / 12000").font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }.navigationTitle("编辑预设").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }
                        .disabled(preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || preset.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                }
        }
    }
    private func save() {
        do {
            var clean = preset; clean.name = clean.name.trimmingCharacters(in: .whitespacesAndNewlines); clean.prompt = clean.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            var values = companion.settings.resolvedGlobalPrompts
            if let index = values.firstIndex(where: { $0.id == clean.id }) { values[index] = clean } else { values.append(clean) }
            try companion.saveGlobalPrompts(values); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

extension CompanionModel {
    func saveGlobalPrompts(_ values: [GlobalPromptPreset]) throws {
        guard let store else { throw MoReadError.invalid("伴读设置尚未打开。") }
        var next = settings; next.globalPrompts = values
        try store.save(next); settings = next
    }
}
