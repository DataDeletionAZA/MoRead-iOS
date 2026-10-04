import SwiftUI
import MoReadCore

struct ReviewRecordEditor: View {
    let entry: ReadingReviewEntry
    var body: some View {
        NavigationStack {
            switch entry.content {
            case .note(let note): ReadingNoteEditor(book: entry.book, original: note)
            case .annotation(let annotation): ReviewAnnotationEditor(entry: entry, original: annotation)
            }
        }
    }
}

private struct ReviewAnnotationEditor: View {
    let entry: ReadingReviewEntry
    let original: Annotation
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var note: String
    @State private var style: String
    @State private var error: String?
    @State private var discarding = false
    private var changed: Bool { note != original.note || style != original.style }
    init(entry: ReadingReviewEntry, original: Annotation) {
        self.entry = entry; self.original = original
        _note = State(initialValue: original.note); _style = State(initialValue: original.style)
    }
    var body: some View {
        Form {
            Section("原文") { Text(original.passage.text).textSelection(.enabled) }
            Section("想法") { TextEditor(text: $note).frame(minHeight: 180).accessibilityIdentifier("review-annotation-note") }
            Picker("划线样式", selection: $style) {
                Text("荧光").tag("highlight"); Text("下划线").tag("underline"); Text("波浪线").tag("wave")
            }.accessibilityIdentifier("review-annotation-style")
        }.navigationTitle("编辑批注").interactiveDismissDisabled(changed)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { if changed { discarding = true } else { dismiss() } } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.accessibilityIdentifier("review-annotation-save") }
            }
            .alert("放弃未保存的修改？", isPresented: $discarding) {
                Button("放弃修改", role: .destructive) { dismiss() }
                Button("继续编辑", role: .cancel) { }
            }
            .alert("未能保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好") { error = nil }
            } message: { Text(error ?? "") }
    }
    private func save() {
        do {
            guard let book = library.books.first(where: { $0.id == entry.book.id }) else { throw MoReadError.invalid("书籍已删除。") }
            try library.modifyRecords(for: book) { try ReadingReview.editAnnotation(entry, note: note, style: style, book: book, records: &$0) }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
