import SwiftUI
import MoReadCore

struct StorageView: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var sizes: [UUID: Int64] = [:]
    var body: some View {
        List {
            Section {
                LabeledContent("书籍与阅读记录", value: ByteCountFormatter.string(fromByteCount: sizes.values.reduce(0, +), countStyle: .file))
            }
            bookSection("本机书籍", books: model.books.filter { !$0.removed })
            bookSection("保留的阅读记录", books: model.books.filter(\.removed))
        }.navigationTitle("存储与阅读记录")
            .task(id: model.books) {
                model.perform {
                    var values: [UUID: Int64] = [:]
                    for book in model.books { values[book.id] = try model.store?.storageBytes(for: book) ?? 0 }
                    sizes = values
                }
            }
    }
    private func bookSection(_ title: String, books: [Book]) -> some View {
        Section(title) {
            ForEach(books) { book in
                NavigationLink {
                    StoredBookView(bookID: book.id)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(book.title)
                        Text((book.hasBody ? "含正文 · " : "阅读记录 · ") + ByteCountFormatter.string(fromByteCount: sizes[book.id] ?? 0, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct StoredBookView: View {
    let bookID: UUID
    @EnvironmentObject private var model: LibraryModel
    @EnvironmentObject private var companion: CompanionModel
    @EnvironmentObject private var speech: SpeechPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var records = BookRecords()
    @State private var clear = false
    @State private var deleting = false
    @State private var working = false
    @State private var exported: String?
    private var book: Book? { model.books.first { $0.id == bookID } }
    var body: some View {
        List {
            if let book {
                Section("阅读记录") {
                    LabeledContent("进度", value: book.progress.formatted(.percent.precision(.fractionLength(0))))
                    LabeledContent("阅读时长", value: "\(Int(records.readingSeconds.values.reduce(0, +) / 60)) 分钟")
                    LabeledContent("状态", value: book.state)
                    if !book.hasBody { Text("正文已清理，阅读记录保存在本机。").foregroundStyle(.secondary) }
                }
                Section("书签") {
                    ForEach(records.bookmarks) { bookmark in Text(bookmark.label).textSelection(.enabled) }
                }
                Section("笔记与批注") {
                    NavigationLink("读书笔记与梗概") { ReadingNotesView(bookID: bookID) }
                    ForEach(records.annotations) { annotation in
                        VStack(alignment: .leading, spacing: 8) {
                            if annotation.characterName != nil { Text(annotation.authorLabel).font(.caption).foregroundStyle(.secondary) }
                            Text(annotation.passage.text).foregroundStyle(.secondary)
                            if !annotation.note.isEmpty { Text(annotation.note) }
                        }.textSelection(.enabled)
                    }
                    if let exported { ShareLink("导出笔记", item: exported) }
                }
                Section("伴读话题") {
                    ForEach(companion.conversations.filter { $0.bookID == bookID }) { conversation in
                        NavigationLink(conversation.title) { CompanionChat(conversationID: conversation.id) }
                    }
                }
                Section {
                    if book.hasBody {
                        if book.removed { Button("放回书架") { var value = book; value.removed = false; model.update(value, immediate: true) } }
                        Button("清理正文，保留记录", role: .destructive) { clear = true }.accessibilityIdentifier("clear-book-body")
                    }
                    Button("彻底删除书籍与阅读记录", role: .destructive) { deleting = true }
                }
            }
        }.navigationTitle(book?.title ?? "阅读记录")
            .disabled(working)
            .task(id: model.recordsRevision) {
                model.perform {
                    if let book, let store = model.store { records = try store.records(for: book); exported = try store.notesMarkdown(for: book) }
                }
            }
            .alert("清理正文？", isPresented: $clear) {
                Button("取消", role: .cancel) {}
                Button("清理正文", role: .destructive) {
                    working = true
                    Task {
                        await speech.stopAndWait(); await companion.stopAndWait()
                        model.clearBody(bookID); working = false
                    }
                }
            } message: { Text("将移除本机保存的原书和解析正文，保留进度、书签、笔记及聊天记录。原始导入来源不受影响。") }
            .alert("彻底删除？", isPresented: $deleting) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    guard let book else { return }
                    speech.stop(); model.remove(book, permanently: true)
                    if self.book == nil { dismiss() }
                }
            } message: { Text("书籍、进度、书签和笔记将从本机删除。伴读话题可在伴读页面单独管理。") }
    }
}
