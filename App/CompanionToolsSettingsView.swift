import SwiftUI
import MoReadCore

struct CompanionToolsSettingsView: View {
    @EnvironmentObject private var companion: CompanionModel
    var body: some View {
        Form {
            Section {
                Toggle("允许伴读使用工具", isOn: Binding(get: { companion.settings.toolsEnabled ?? true }, set: { companion.stop(); companion.settings.toolsEnabled = $0; companion.saveSettings() })).accessibilityIdentifier("tools-enabled")
            } footer: { Text("伴读可查询已读资料与角色记忆，也可在当前书籍中保存批注、笔记和剧情梗概。书库伴读还可准备标签和分组整理预览，由你确认后应用。在绘图设置开启伴读绘图后，角色也可按请求生成并保存插图，每条回复最多 4 张。每种工具可按角色开关。查询到的内容会发送给当前聊天服务商；最多连续进行 8 轮查询，每轮可查多项资料，可能增加 API 费用。") }
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
            Section { Text("工具遵守每本书的已读边界，角色只能更新自己的笔记；你编辑过的内容会受到保护。聊天回复中的“查询过程”可以展开查看结果；点击“停止回复”会同时停止继续查询。") }
        }.navigationTitle("伴读工具")
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
        }.navigationTitle("可用工具")
    }
}
