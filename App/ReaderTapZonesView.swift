import SwiftUI
import MoReadCore

struct ReaderTapZonesView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("reader.tapZones") private var saved = Data()
    @State private var draft = ReaderTapZones()
    @State private var enabled = false
    @State private var loaded = false
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Toggle("自定义点按区域", isOn: $enabled).accessibilityIdentifier("tap-zones-enabled")
                Text("轻点方格分配操作。页眉和页脚各占阅读区域高度的 8%，其余部分分成九格；横屏时保持相同比例。").font(.caption).foregroundStyle(.secondary)
                if enabled {
                    row([9, 10], height: 64)
                    ForEach(0..<3) { index in row(Array(index * 3..<index * 3 + 3), height: 100) }
                    row([11, 12], height: 64)
                    if !draft.isValid { Text("至少保留一个菜单区域，才能随时退出沉浸阅读。").foregroundStyle(.red).accessibilityIdentifier("tap-zones-invalid") }
                    Button("重置区域分配") { draft = ReaderTapZones() }
                }
            }.padding()
        }
        .navigationTitle("操作区域")
        .toolbar { ToolbarItem(placement: .confirmationAction) {
            Button("保存") { saved = enabled ? draft.encoded() : Data(); dismiss() }
                .disabled(enabled && !draft.isValid).accessibilityIdentifier("tap-zones-save")
        } }
        .onAppear {
            guard !loaded else { return }; loaded = true
            if let value = ReaderTapZones(data: saved) { draft = value; enabled = true }
        }
    }
    private func row(_ indices: [Int], height: CGFloat) -> some View {
        HStack(spacing: 8) {
            ForEach(indices, id: \.self) { index in
                NavigationLink {
                    List(ReaderTapAction.allCases, id: \.self) { action in
                        Button { draft.actions[index] = action } label: {
                            HStack { Text(action.label); Spacer(); if draft.actions[index] == action { Image(systemName: "checkmark") } }
                        }.accessibilityIdentifier("tap-action-" + action.rawValue)
                    }.navigationTitle(ReaderTapZones.labels[index])
                } label: {
                    VStack(spacing: 4) { Text(ReaderTapZones.labels[index]).font(.caption); Text(draft.actions[index].label).font(.subheadline) }
                        .frame(maxWidth: .infinity, minHeight: height).padding(.horizontal, 3)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                }.accessibilityIdentifier("tap-zone-\(index)")
            }
        }
    }
}
