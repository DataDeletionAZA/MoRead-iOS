import SwiftUI
import MoReadCore

struct ProactiveSettingsView: View {
    @EnvironmentObject private var companion: CompanionModel
    private var policy: ProactiveSettings { (companion.settings.proactive ?? ProactiveSettings()).validated() }
    private func field<T>(_ key: WritableKeyPath<ProactiveSettings, T>) -> Binding<T> {
        Binding(get: { policy[keyPath: key] }, set: { value in
            var copy = policy; copy[keyPath: key] = value
            companion.stopAnnotations(); companion.settings.proactive = copy.validated(); companion.saveSettings()
        })
    }
    var body: some View {
        Form {
            Section {
                Toggle("自动随读段评", isOn: field(\.enabled)).accessibilityIdentifier("proactive-enabled")
            } footer: { Text("读完一章后，让角色为其中的段落写评论。开启后会自动将已读原文与角色资料发给所选服务商，按服务商规则计费。") }
            Section("模型") {
                Picker("段评服务商", selection: field(\.providerID)) {
                    Text("跟随聊天服务商").tag(UUID?.none)
                    ForEach(companion.settings.providers) { Text("\($0.name) · \($0.model)").tag(Optional($0.id)) }
                }
                NavigationLink("管理 AI 服务商") { AISettingsView() }
            }
            Section {
                ForEach(companion.characters) { card in
                    Toggle(card.name, isOn: Binding(get: { policy.characterIDs.contains(card.id) }, set: { enabled in
                        var ids = policy.characterIDs; if enabled { ids.append(card.id) } else { ids.removeAll { $0 == card.id } }
                        field(\.characterIDs).wrappedValue = ids
                    }))
                }
            } header: { Text("参与角色") } footer: { Text("未勾选时使用当前伴读角色。多位角色共享每章和每日额度。") }
            Section("数量") {
                Toggle("每章不限条数", isOn: Binding(get: { policy.maximumPerChapter == -1 }, set: { field(\.maximumPerChapter).wrappedValue = $0 ? -1 : 2 }))
                if policy.maximumPerChapter != -1 {
                    Stepper("每章最多 \(policy.maximumPerChapter) 条", value: field(\.maximumPerChapter), in: 1...10).accessibilityIdentifier("proactive-chapter-limit")
                }
                Stepper("每章期望至少 \(policy.minimumPerChapter) 条", value: field(\.minimumPerChapter), in: 0...(policy.maximumPerChapter == -1 ? 10 : policy.maximumPerChapter))
                Toggle("每日不限条数", isOn: Binding(get: { policy.dailyMaximum == -1 }, set: { field(\.dailyMaximum).wrappedValue = $0 ? -1 : 10 }))
                if policy.dailyMaximum != -1 { Stepper("每日最多 \(policy.dailyMaximum) 条", value: field(\.dailyMaximum), in: 1...50) }
                Text("期望数量不会强迫模型凑数。评论必须引用真实原文，保存后可在阅读页“批注”查看。").font(.caption).foregroundStyle(.secondary)
            }
            if let status = companion.annotationStatus {
                Section("进度") {
                    Text(status)
                    if companion.annotationRunning { Button("停止本次段评", role: .cancel) { companion.stopAnnotations() } }
                }
            }
        }.navigationTitle("随读段评")
    }
}
