import SwiftUI
import MoReadCore

struct ReadingNotesView: View {
    let bookID: UUID
    @EnvironmentObject private var library: LibraryModel
    @State private var notes: [ReadingNote] = []
    @State private var filter = "all"
    @State private var query = ""
    @State private var creating = false
    private var book: Book? { library.books.first { $0.id == bookID } }
    private var visible: [ReadingNote] { notes.filter { (filter == "all" || $0.kind == filter) && (query.isEmpty || ($0.title + $0.content).localizedCaseInsensitiveContains(query)) }.sorted { $0.updatedAt > $1.updatedAt } }
    var body: some View {
        List {
            Picker("内容类型", selection: $filter) { Text("全部").tag("all"); Text("笔记").tag("note"); Text("梗概").tag("plot_summary") }.pickerStyle(.segmented)
            if visible.isEmpty { Text("还没有符合条件的笔记。可以自己新建，也可以在这本书的伴读中请角色保存。").foregroundStyle(.secondary) }
            if let book {
                ForEach(visible) { note in
                    NavigationLink {
                        ReadingNoteDetail(bookID: bookID, noteID: note.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(note.title).font(.headline)
                            Text(note.authorLabel + " · " + (note.kind == "plot_summary" ? "剧情梗概" : "笔记")).font(.caption).foregroundStyle(.secondary)
                            Text(note.content).lineLimit(2).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }.accessibilityIdentifier("reading-note-" + note.title)
                }.onDelete { offsets in
                    let ids = Set(offsets.map { visible[$0].id })
                    library.perform { try library.modifyRecords(for: book) { $0.notes?.removeAll { ids.contains($0.id) } } }
                }
                if !notes.isEmpty, let markdown = try? library.store?.notesMarkdown(for: book) { ShareLink("导出笔记与批注", item: markdown) }
            }
        }.navigationTitle("读书笔记与梗概").searchable(text: $query, prompt: "搜索标题和正文")
            .toolbar { Button("新建笔记", systemImage: "square.and.pencil") { creating = true } }
            .sheet(isPresented: $creating) { if let book { NavigationStack { ReadingNoteEditor(book: book, original: nil) } } }
            .task(id: library.recordsRevision) { reload() }
            .onAppear { reload() }
    }
    private func reload() { library.perform { if let book, let store = library.store { notes = try store.records(for: book).notes ?? [] } } }
}

private struct ReadingNoteDetail: View {
    let bookID: UUID
    let noteID: UUID
    @EnvironmentObject private var library: LibraryModel
    @State private var note: ReadingNote?
    @State private var editing = false
    private var book: Book? { library.books.first { $0.id == bookID } }
    var body: some View {
        ScrollView {
            if let note {
                VStack(alignment: .leading, spacing: 18) {
                    Text(note.authorLabel).font(.caption).foregroundStyle(.secondary)
                    if let from = note.fromChapter, let to = note.toChapter { Text("覆盖第 \(from)–\(to) 章").font(.caption).foregroundStyle(.secondary) }
                    Text(.init(note.content)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    ShareLink("分享这篇笔记", item: "# \(note.title)\n\n\(note.content)")
                }.padding()
            }
        }.navigationTitle(note?.title ?? "笔记")
            .toolbar { Button("编辑") { editing = true }.disabled(note == nil) }
            .sheet(isPresented: $editing) { if let book, let note { NavigationStack { ReadingNoteEditor(book: book, original: note) } } }
            .task(id: library.recordsRevision) { library.perform { if let book { note = try library.store?.records(for: book).notes?.first { $0.id == noteID } } } }
    }
}

private struct ReadingNoteEditor: View {
    let book: Book
    let original: ReadingNote?
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ReadingNote
    @State private var error: String?
    init(book: Book, original: ReadingNote?) {
        self.book = book; self.original = original
        _draft = State(initialValue: original ?? ReadingNote(title: "", content: "", book: book))
    }
    var body: some View {
        Form {
            TextField("标题", text: $draft.title).accessibilityIdentifier("reading-note-title")
            Section("正文") { TextEditor(text: $draft.content).frame(minHeight: 300).accessibilityIdentifier("reading-note-content") }
            if original?.characterID != nil { Text("保存你的修改后，角色不能自动覆盖这篇内容。").font(.caption).foregroundStyle(.secondary) }
        }.navigationTitle(original == nil ? "新建笔记" : "编辑笔记")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } }
            }
            .alert("未能保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好") { error = nil } } message: { Text(error ?? "") }
    }
    private func save() {
        do {
            guard let currentBook = library.books.first(where: { $0.id == book.id }) else { throw MoReadError.invalid("书籍已删除。") }
            var value = draft; value.title = value.title.trimmingCharacters(in: .whitespacesAndNewlines); value.content = value.content.trimmingCharacters(in: .whitespacesAndNewlines)
            try value.validate(); value.updatedAt = Date()
            if original?.characterID != nil { value.userEdited = true }
            value.sourceThrough = max(value.sourceThrough, currentBook.readThrough)
            try library.modifyRecords(for: currentBook) { records in
                var notes = records.notes ?? []
                if let original {
                    guard let index = notes.firstIndex(where: { $0.id == original.id }), notes[index] == original else { throw MoReadError.invalid("这篇笔记已变化，请重新打开后编辑。") }
                    notes[index] = value
                } else { notes.append(value) }
                records.notes = notes
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
