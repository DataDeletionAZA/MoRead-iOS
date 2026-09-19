import SwiftUI
import MoReadCore

struct UserMaskSettingsView: View {
    @EnvironmentObject private var companion: CompanionModel
    @State private var editing: UserMask?
    private var settings: UserMaskSettings { companion.settings.userMasks ?? UserMaskSettings() }
    var body: some View {
        List {
            Section {
                Toggle("使用扮演身份", isOn: Binding(get: { settings.enabled }, set: { enabled in _ = companion.updateMasks { $0.enabled = enabled } }))
                    .disabled(settings.masks.isEmpty).accessibilityIdentifier("mask-enabled")
                Text("当前身份：\(companion.settings.currentIdentity.label)").accessibilityIdentifier("current-identity")
            } footer: { Text("扮演身份描述你在对话中是谁。关闭后恢复本人称呼；已发送的消息保留当时的身份。") }
            Section("我的身份") {
                ForEach(settings.masks) { mask in
                    HStack {
                        Button { _ = companion.updateMasks { $0.activeMaskID = mask.id; $0.enabled = true } } label: {
                            HStack {
                                VStack(alignment: .leading) { Text(mask.name); Text(mask.description).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                                Spacer()
                                if settings.activeMaskID == mask.id { Image(systemName: "checkmark.circle.fill").accessibilityLabel("已选择") }
                            }
                        }.accessibilityIdentifier("select-mask-\(mask.name)")
                        Button("编辑", systemImage: "pencil") { editing = mask }.labelStyle(.iconOnly).buttonStyle(.borderless).accessibilityIdentifier("edit-mask-\(mask.name)")
                    }
                }.onDelete { offsets in
                    let ids = Set(offsets.map { settings.masks[$0].id }); _ = companion.updateMasks { $0.remove(ids) }
                }
                Button("新建身份", systemImage: "plus") { editing = UserMask() }
            }
        }.navigationTitle("我的身份")
            .sheet(item: $editing) { UserMaskEditor(mask: $0) }
    }
}

private struct UserMaskEditor: View {
    @State var mask: UserMask
    @EnvironmentObject private var companion: CompanionModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                TextField("身份名称", text: $mask.name).accessibilityIdentifier("mask-name")
                    .onChange(of: mask.name) { _, value in mask.name = String(value.prefix(24)) }
                Section("身份设定") {
                    TextEditor(text: $mask.description).frame(minHeight: 180).accessibilityIdentifier("mask-description")
                        .onChange(of: mask.description) { _, value in mask.description = String(value.prefix(4000)) }
                    Text("\(mask.description.count) / 4000 字").font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("身份资料")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") { if companion.updateMasks({ try $0.save(mask) }) { dismiss() } }.disabled(mask.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                }
        }
    }
}

extension CompanionModel {
    @discardableResult
    func updateMasks(_ action: (inout UserMaskSettings) throws -> Void) -> Bool {
        do {
            guard let store else { throw MoReadError.invalid("身份资料存储尚未打开。") }
            var copy = settings, masks = settings.userMasks ?? UserMaskSettings()
            try action(&masks); copy.userMasks = masks
            try store.save(copy); settings = copy
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
}
