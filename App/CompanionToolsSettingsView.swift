import SwiftUI
import MoReadCore

struct CompanionToolsSettingsView: View {
    @EnvironmentObject private var companion: CompanionModel
    var body: some View {
        Form {
            Section {
                Toggle("允许伴读主动查询资料", isOn: Binding(get: { companion.settings.toolsEnabled ?? true }, set: { companion.stop(); companion.settings.toolsEnabled = $0; companion.saveSettings() })).accessibilityIdentifier("tools-enabled")
            } footer: { Text("伴读可根据问题查看书籍目录、进度、已读原文和笔记，也可以回忆这个角色保存的长期记忆。查询到的内容会发送给当前聊天服务商；最多连续进行 8 轮查询，每轮可查多项资料，可能增加 API 费用。") }
            Section("角色的可用工具") {
                ForEach(companion.characters) { card in
                    NavigationLink(card.name) {
                        CharacterToolsView(enabled: Binding(get: { companion.characters.first { $0.id == card.id }?.enabledTools }, set: { value in
                            guard var current = companion.characters.first(where: { $0.id == card.id }) else { return }
                            companion.stop(); current.enabledTools = value; companion.saveCard(current, select: false)
                        }))
                    }
                }
            }
            Section { Text("查询仍遵守每本书的已读边界。聊天回复中的“查询过程”可以展开查看结果；点击“停止回复”会同时停止继续查询。") }
        }.navigationTitle("伴读查询工具")
    }
}

struct CharacterToolsView: View {
    @Binding var enabled: [String]?
    var body: some View {
        List {
            ForEach(ReaderTools.titles.keys.sorted(), id: \.self) { name in
                Toggle(ReaderTools.titles[name] ?? name, isOn: Binding(get: { enabled?.contains(name) ?? true }, set: { value in
                    var names = Set(enabled ?? Array(ReaderTools.titles.keys)); if value { names.insert(name) } else { names.remove(name) }; enabled = names.sorted()
                }))
            }
        }.navigationTitle("可用查询工具")
    }
}
