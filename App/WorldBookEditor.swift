import SwiftUI
import UniformTypeIdentifiers
import MoReadCore

struct WorldBookEditor: View {
    @Binding var entries: [LoreEntry]
    @State private var picker = false
    @State private var message: String?
    @State private var error: String?
    var body: some View {
        List {
            Section {
                Button("导入世界书 JSON", systemImage: "square.and.arrow.down") { picker = true }
                Button("新建设定", systemImage: "plus") { entries.append(LoreEntry(order: Double(entries.count))) }
                if let message { Text(message).foregroundStyle(.secondary) }
            } footer: { Text("导入的条目会追加到当前角色；回到角色资料点击“保存”后生效。") }
            ForEach($entries) { $entry in
                NavigationLink {
                    Form {
                        TextField("名称", text: $entry.title)
                        Toggle("启用", isOn: $entry.enabled)
                        Toggle("始终使用", isOn: $entry.constant)
                        Section("正文") { TextEditor(text: $entry.content).frame(minHeight: 180).accessibilityIdentifier("lore-content") }
                        Section("触发词，每行一个") {
                            TextEditor(text: Binding(get: { entry.keys.joined(separator: "\n") }, set: { entry.keys = $0.components(separatedBy: .newlines) })).frame(minHeight: 90)
                        }
                        Section { TextField("顺序", value: $entry.order, format: .number).keyboardType(.numbersAndPunctuation) }
                    }.navigationTitle("世界书设定")
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(entry.title.isEmpty ? "未命名设定" : entry.title)
                        Text(entry.enabled ? (entry.constant ? "始终使用" : "关键词触发") : "已停用").font(.caption).foregroundStyle(.secondary)
                        Text(entry.content).lineLimit(2).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.onDelete { entries.remove(atOffsets: $0) }
        }.navigationTitle("世界书")
            .fileImporter(isPresented: $picker, allowedContentTypes: [.json]) { result in
                do {
                    let url = try result.get(), scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let imported = try WorldBookImporter.parse(CharacterCardImporter.read(url, limit: 4 * 1024 * 1024))
                    guard imported.count <= 10000 - entries.count else { throw MoReadError.invalid("一个角色最多保存 10000 条设定。") }
                    entries.append(contentsOf: imported); message = "已导入 \(imported.count) 条设定"
                } catch { self.error = error.localizedDescription }
            }
            .alert("世界书未导入", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好", role: .cancel) {} } message: { Text(error ?? "") }
    }
}
