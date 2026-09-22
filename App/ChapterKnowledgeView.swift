import SwiftUI
import MoReadCore

struct ChapterKnowledgeView: View {
    let bookID: UUID
    let onLocate: (SourcePassage) -> Void
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var companion: CompanionModel
    @State private var entries: [ChapterKnowledgeEntry] = []
    @State private var expanded: Set<Int> = []
    @State private var plan: KnowledgePlan?
    @State private var deletion: Int?
    @State private var message: String?
    private var book: Book? { library.books.first { $0.id == bookID && !$0.removed && $0.hasBody } }
    var body: some View {
        List {
            if let book {
                let revision = MemoryBookScope.fingerprint(book.chapters.map(\.revision))
                let visible = entries.filter { $0.visible(in: book, revision: revision) }
                let eligible = book.chapters.filter { $0.length > 0 && ($0.id < book.readThrough.chapter || ($0.id == book.readThrough.chapter && book.readThrough.offset > 0)) }
                Section {
                    ModelAssignmentPicker(task: .knowledge, title: "整理模型")
                    HStack {
                        Button("展开全部") { expanded = Set(eligible.map(\.id)) }
                        Spacer()
                        Button("收起全部") { expanded.removeAll() }
                    }.buttonStyle(.borderless)
                } footer: { Text("只整理已读原文。每次开始前可核对范围与预计调用次数；最多同时整理两项，其余排队。离开此页后继续，退出应用后需重新开始。") }
                if let message { Section { Text(message).foregroundStyle(.red) } }
                if entries.count > visible.count { Text("有 \(entries.count - visible.count) 份提纲因正文或已读范围变化而隐藏，可重新生成。").foregroundStyle(.secondary) }
                if eligible.isEmpty { ContentUnavailableView("还没有已读正文", systemImage: "text.book.closed", description: Text("先阅读一些内容，再来生成提纲。")) }
                ForEach(eligible) { chapter in
                    let entry = visible.first { $0.chapter == chapter.id }
                    let key = KnowledgeJobKey(bookID: bookID, chapter: chapter.id)
                    let running = companion.knowledgeTasks[key] != nil
                    Section {
                        DisclosureGroup(isExpanded: Binding(get: { expanded.contains(chapter.id) }, set: { if $0 { expanded.insert(chapter.id) } else { expanded.remove(chapter.id) } })) {
                            if let entry {
                                Text(entry.content.outline).textSelection(.enabled).accessibilityIdentifier("knowledge-outline-\(chapter.id)")
                                Text(entry.sourceEnd < chapter.length ? "覆盖本章已读部分 · \(entry.sourceEnd) 字" : "覆盖完整章节").font(.caption).foregroundStyle(.secondary)
                                Text(entry.modelLabel).font(.caption).foregroundStyle(.secondary)
                                DisclosureGroup("原文依据（\(entry.content.summary.count)）") {
                                    ForEach(Array(entry.content.summary.enumerated()), id: \.offset) { index, fact in
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text(fact.text)
                                            Text("“\(fact.quote)”").font(.callout).foregroundStyle(.secondary)
                                            Button("核对原文") { locate(entry, fact: fact) }.accessibilityIdentifier("knowledge-locate-\(chapter.id)-\(index)")
                                        }.padding(.vertical, 6)
                                    }
                                }
                            }
                            if running {
                                Button("停止生成", role: .destructive) { companion.stopKnowledge(key) }.accessibilityIdentifier("knowledge-stop-\(chapter.id)")
                            } else {
                                Button(entry == nil ? "生成提纲" : "重新生成") {
                                    do { plan = try companion.previewKnowledge(bookID: bookID, chapter: chapter.id, library: library); message = nil }
                                    catch { message = error.localizedDescription }
                                }.accessibilityIdentifier("knowledge-generate-\(chapter.id)")
                                if entry != nil { Button("删除提纲", role: .destructive) { deletion = chapter.id }.accessibilityIdentifier("knowledge-delete-\(chapter.id)") }
                            }
                            Text(companion.knowledgeStates[key] ?? (entry == nil ? "尚未生成" : "已保存"))
                                .font(.caption).foregroundStyle(.secondary).frame(minHeight: 36, alignment: .leading).accessibilityIdentifier("knowledge-status-\(chapter.id)")
                        } label: { Text(chapter.title) }.buttonStyle(.borderless)
                    }
                }
            } else { Text("书籍正文已移除。") }
        }.navigationTitle("章节提纲")
            .task { reload(); if let book { expanded.insert(book.position.chapter) } }
            .onChange(of: library.recordsRevision) { _, _ in reload() }
            .sheet(item: $plan) { value in
                NavigationStack {
                    Form {
                        LabeledContent("书籍", value: value.source.bookTitle)
                        LabeledContent("章节", value: value.source.chapterTitle)
                        LabeledContent("整理范围", value: value.source.partial ? "本章已读部分" : "完整章节")
                        LabeledContent("原文长度", value: "\(value.source.text.utf16.count) 字")
                        LabeledContent("模型", value: value.provider.name + " · " + value.provider.model).accessibilityElement(children: .combine).accessibilityIdentifier("knowledge-preview-model")
                        LabeledContent("预计调用", value: "\(value.source.requestCount) 次，含纠错最多 \(value.source.maximumRequests) 次")
                        Text("将以上范围内的原文发送给所选 AI 服务商，按服务商规则计费。生成失败或停止时保留旧提纲。")
                        Button("开始生成") { companion.startKnowledge(value, library: library); plan = nil }.accessibilityIdentifier("knowledge-confirm")
                    }.navigationTitle("确认章节整理")
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { plan = nil } } }
                }
            }
            .alert("删除本章提纲？", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } })) {
                Button("取消", role: .cancel) { deletion = nil }
                Button("删除", role: .destructive) {
                    defer { deletion = nil }
                    do {
                        guard let chapter = deletion, companion.knowledgeTasks[.init(bookID: bookID, chapter: chapter)] == nil, !library.maintenance, let storage = library.store else { return }
                        try storage.deleteKnowledge(bookID: bookID, chapter: chapter)
                        companion.knowledgeStates.removeValue(forKey: .init(bookID: bookID, chapter: chapter))
                        library.recordsRevision = UUID()
                    } catch { message = error.localizedDescription }
                }
            }
    }
    private func reload() {
        do { if let book, let storage = library.store { entries = try storage.records(for: book).chapterKnowledge ?? [] } else { entries = [] } }
        catch { message = error.localizedDescription }
    }
    private func locate(_ entry: ChapterKnowledgeEntry, fact: KnowledgeFact) {
        do {
            guard !library.maintenance, let storage = library.store else { return }
            library.flush(); onLocate(try storage.locateKnowledge(entry, fact: fact))
        } catch { message = error.localizedDescription }
    }
}
