import SwiftUI
import MoReadCore

struct ConversationScopeView: View {
    let conversationID: UUID
    @EnvironmentObject private var companion: CompanionModel
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: [UUID] = []
    @State private var query = ""
    @State private var error: String?
    private var conversation: Conversation? { companion.conversations.first { $0.id == conversationID } }
    private var available: [Book] { library.books.filter { !$0.removed && $0.hasBody }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } }
    private func progress(_ position: ReadingPosition, book: Book?) -> String {
        guard let book, book.chapters.indices.contains(position.chapter), position.offset >= 0, position.offset <= book.chapters[position.chapter].length else { return "来源需重新核对" }
        return position == ReadingPosition() ? "尚未阅读" : "第 \(position.chapter + 1) 章 · 已读 \(position.offset) 字"
    }
    var body: some View {
        List {
            Section {
                Text("已选 \(selected.count) / 4 本。重点书籍表示这次更想聊的内容；其他书仍可按需查阅。每本书只提供你已读到的部分。")
                Button("清空重点书籍") { selected = [] }.disabled(selected.isEmpty)
                ForEach(selected.filter { id in !available.contains { $0.id == id } }, id: \.self) { id in
                    Button("移除已不可用的重点书籍", role: .destructive) { selected.removeAll { $0 == id } }
                }
            }
            Section("重点书籍") {
                ForEach(available.filter { query.isEmpty || ($0.title + $0.author).localizedCaseInsensitiveContains(query) }) { book in
                    Toggle(isOn: Binding(get: { selected.contains(book.id) }, set: { enabled in
                        if enabled { if selected.count < 4 { selected.append(book.id) } }
                        else { selected.removeAll { $0 == book.id } }
                    })) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(book.title)
                            Text(progress(book.readThrough, book: book)).font(.caption).foregroundStyle(.secondary)
                        }
                    }.disabled(!selected.contains(book.id) && selected.count >= 4).accessibilityIdentifier("focus-book-" + book.title)
                }
            }
            if let conversation, !conversation.sourceLimits.isEmpty {
                Section("本话题已关联的范围") {
                    ForEach(conversation.sourceLimits.keys.sorted { $0.uuidString < $1.uuidString }, id: \.self) { id in
                        let book = library.books.first { $0.id == id }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(book?.title ?? "已移除的书籍")
                            if let position = conversation.sourceLimits[id] { Text(progress(position, book: book)).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }.navigationTitle("重点书籍").searchable(text: $query, prompt: "搜索书名或作者")
            .onAppear { selected = conversation?.focusedBookIDs ?? [] }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.disabled(companion.busy || library.maintenance) }
            }
            .alert("未能保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好") { error = nil } } message: { Text(error ?? "") }
    }
    private func save() {
        do {
            guard !companion.busy, !library.maintenance, let store = companion.store,
                  let index = companion.conversations.firstIndex(where: { $0.id == conversationID && $0.bookID == nil }),
                  selected.allSatisfy({ id in available.contains { $0.id == id } }) else { throw MoReadError.invalid("话题或书籍已变化，请重新打开。") }
            var value = companion.conversations[index]; value.focusedBookIDs = selected
            try value.validateFocus(); try store.save(value); companion.conversations[index] = value; dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
