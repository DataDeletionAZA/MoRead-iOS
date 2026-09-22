import SwiftUI
import MoReadCore

struct PersonaMemorySettingsView: View {
    @EnvironmentObject private var companion: CompanionModel
    private var settings: PersonaMemorySettings { companion.settings.personaMemory ?? PersonaMemorySettings() }
    private func field<T>(_ key: WritableKeyPath<PersonaMemorySettings, T>) -> Binding<T> {
        Binding(get: { settings[keyPath: key] }, set: {
            companion.personaMemoryTask?.cancel()
            var value = settings; value[keyPath: key] = $0
            companion.settings.personaMemory = value; companion.saveSettings()
        })
    }
    var body: some View {
        Form {
            Section {
                Toggle("启用角色长期记忆", isOn: field(\.enabled)).accessibilityIdentifier("persona-memory-enabled")
                ModelAssignmentPicker(task: .memory, title: "记忆整理服务商")
                NavigationLink("向量服务商与模型") { VectorMemoryView() }
                Toggle("阅读时允许跨书回忆", isOn: field(\.crossBook))
            } footer: { Text("开启后，聊天会自动提炼有用信息并按意思回忆。对话与候选记忆会发送给所选整理服务商，记忆文本和检索问题会发送给向量服务商，可能产生 API 费用。关闭后保留本机记忆，停止整理和调用。") }
            Section("各角色的记忆") {
                ForEach(companion.characters) { card in NavigationLink(card.name) { PersonaMemoryView(characterID: card.id) } }
            }
            if let status = companion.personaMemoryStatus { Section("最近的记忆处理") { Text(status).font(.caption) } }
        }.navigationTitle("长期记忆")
    }
}

struct PersonaMemoryView: View {
    let characterID: UUID
    var conversationID: UUID? = nil
    @EnvironmentObject private var companion: CompanionModel
    @EnvironmentObject private var library: LibraryModel
    @State private var entries: [PersonaMemory] = []
    @State private var profile = MemoryProfile()
    @State private var validOrigins: Set<MemoryOrigin> = []
    @State private var editing: PersonaMemory?
    @State private var editingProfile = false
    @State private var clear = false
    @State private var query = ""
    private var policy: PersonaMemorySettings { companion.settings.personaMemory ?? PersonaMemorySettings() }
    var body: some View {
        List {
            Section {
                Toggle("这个角色可以记住我", isOn: Binding(get: { !policy.disabledCharacters.contains(characterID) }, set: { enabled in
                    companion.personaMemoryTask?.cancel()
                    var copy = policy
                    if enabled { copy.disabledCharacters.remove(characterID) } else { copy.disabledCharacters.insert(characterID) }
                    companion.settings.personaMemory = copy; companion.saveSettings()
                }))
                if !policy.enabled { Text("长期记忆总开关已关闭。").font(.caption).foregroundStyle(.secondary) }
                NavigationLink("长期记忆设置") { PersonaMemorySettingsView() }
                if let conversationID {
                    Button("整理本次对话") { companion.consolidateMemory(conversationID, library: library, onClose: true, explain: true) }
                        .disabled(!policy.enabled || policy.disabledCharacters.contains(characterID) || companion.personaMemoryTask != nil)
                }
                if companion.personaMemoryTask != nil { Button("停止记忆处理", role: .cancel) { companion.personaMemoryTask?.cancel() } }
                if let status = companion.personaMemoryStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
            Section("对本人的了解") {
                Text(profile.text.isEmpty ? "还没有用户画像。" : profile.text).accessibilityIdentifier("memory-profile")
                if !profile.origins.allSatisfy({ validOrigins.contains($0) }) { Text("来源已变化，暂不用于回复。").font(.caption).foregroundStyle(.secondary) }
                Button("编辑用户画像") { editingProfile = true }
            }
            Section("已保存 \(entries.count) 条记忆") {
                ForEach(entries.filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) }) { entry in
                    Button { editing = entry } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.text).foregroundStyle(.primary)
                            Text(scopeLabel(entry))
                                .font(.caption).foregroundStyle(.secondary)
                            if !entry.origins.allSatisfy({ validOrigins.contains($0) }) { Text("来源已变化，暂不用于回复").font(.caption).foregroundStyle(.secondary) }
                        }
                    }.accessibilityIdentifier("memory-entry-\(entry.id)")
                        .swipeActions { Button("遗忘", role: .destructive) { companion.forgetMemory(entry.id, characterID: characterID, library: library) } }
                }
            }
            Section {
                Button("重新整理记忆向量") { companion.reindexMemories(characterID: characterID, library: library) }.disabled(entries.isEmpty || companion.personaMemoryTask != nil)
                Text("更换向量模型后可重新整理，让原有记忆继续参与检索。").font(.caption).foregroundStyle(.secondary)
                Button("清空这个角色的记忆", role: .destructive) { clear = true }.disabled(entries.isEmpty && profile.text.isEmpty)
            }
        }.navigationTitle("角色记忆").searchable(text: $query, prompt: "查找记忆")
            .task { refresh() }
            .onChange(of: companion.personaMemoryRevision) { _, _ in refresh() }
            .sheet(item: $editing) { entry in
                MemoryTextEditor(title: "编辑记忆", text: entry.text, limit: 500) { text, done in companion.editMemory(entry, text: text, library: library, onSaved: done) }
            }
            .sheet(isPresented: $editingProfile) {
                MemoryTextEditor(title: "用户画像", text: profile.text, limit: 800) { text, done in companion.saveMemoryProfile(text, characterID: characterID, library: library, onSaved: done) }
            }
            .alert("清空这个角色的记忆？", isPresented: $clear) {
                Button("取消", role: .cancel) {}
                Button("清空", role: .destructive) { companion.forgetMemory(nil, characterID: characterID, library: library) }
            } message: { Text("将清除这个角色的长期记忆与用户画像，聊天记录保留。") }
    }
    private func scopeLabel(_ entry: PersonaMemory) -> String {
        let identity = entry.identity?.label ?? "本人"
        let book = library.books.first { $0.id == entry.bookID }?.title ?? "全局对话"
        return identity + " · " + book
    }
    private func refresh() {
        guard let root = library.store?.root else { return }
        companion.perform { let store = try PersonaMemoryStore(root: root); entries = try store.list(characterID); profile = try store.profile(characterID); validOrigins = MemoryOrigin.validated(entries.flatMap(\.origins) + profile.origins, books: library.books, conversations: companion.conversations) }
    }
}

private struct MemoryTextEditor: View {
    let title: String
    @State var text: String
    let limit: Int
    let save: (String, @escaping () -> Void) -> Void
    @EnvironmentObject private var companion: CompanionModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                TextEditor(text: $text).frame(minHeight: 220).accessibilityIdentifier("memory-text-editor")
                    .onChange(of: text) { _, value in text = String(value.prefix(limit)) }
                Text("\(text.count) / \(limit) 字").font(.caption).foregroundStyle(.secondary)
                if let status = companion.personaMemoryStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
            }.navigationTitle(title)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") { save(text) { dismiss() } }.disabled(companion.personaMemoryTask != nil) }
                }
        }
    }
}
