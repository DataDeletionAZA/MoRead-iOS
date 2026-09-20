import SwiftUI
import MoReadCore

struct LibraryOrganizationPreview: View {
    let conversationID: UUID
    let plan: LibraryOrganizationPlan
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var companion: CompanionModel
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    private var decision: String? { library.organization.organizationDecisions?[plan.id] }
    var body: some View {
        List {
            Section {
                Text(decision == "applied" ? "已应用到书架" : decision == "cancelled" ? "已取消，书架未改变" : "请核对下面的调整。确认后会一次应用到书架。")
                    .accessibilityIdentifier("organization-status")
                if companion.busy { Text("请等待当前回复完成再处理方案。").foregroundStyle(.secondary) }
            }
            ForEach(plan.changes) { change in
                Section(change.title) {
                    LabeledContent("现有标签", value: change.beforeTags.isEmpty ? "无" : change.beforeTags.map(\.name).joined(separator: "、"))
                    if !change.addTags.isEmpty { LabeledContent("添加标签", value: change.addTags.joined(separator: "、")) }
                    if !change.removeTags.isEmpty { LabeledContent("移除标签", value: change.removeTags.joined(separator: "、")) }
                    if let group = change.groupName {
                        LabeledContent("原分组", value: change.beforeGroup?.name ?? "未分组")
                        LabeledContent("移入分组", value: group)
                    }
                }
            }
            if decision == nil {
                Section {
                    Button("确认应用到书架", systemImage: "checkmark") { resolve(apply: true) }.accessibilityIdentifier("apply-organization")
                    Button("取消这份方案", role: .destructive) { resolve(apply: false) }.accessibilityIdentifier("cancel-organization")
                }.disabled(companion.busy || library.maintenance)
            }
        }.navigationTitle("书架整理预览")
            .toolbar { Button("完成") { dismiss() } }
            .alert("未能处理方案", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好") { error = nil } } message: { Text(error ?? "") }
    }
    private func resolve(apply: Bool) {
        do {
            guard !companion.busy, !library.maintenance, let store = library.store,
                  let conversation = companion.conversations.first(where: { $0.id == conversationID }), conversation.bookID == nil,
                  conversation.messages.contains(where: { message in message.role == "assistant" && (message.toolTrace ?? []).contains { $0.state == "succeeded" && $0.call.name == "propose_library_organization" && $0.organizationPlan == plan } }) else { throw MoReadError.invalid("话题或方案已变化，请重新打开。") }
            var shelf = try store.organization()
            try plan.resolve(apply: apply, books: library.books, shelf: &shelf)
            // The decision receipt and all assignments share the same atomic file replacement.
            try store.saveOrganization(shelf)
            library.organization = shelf
        } catch { self.error = error.localizedDescription }
    }
}
