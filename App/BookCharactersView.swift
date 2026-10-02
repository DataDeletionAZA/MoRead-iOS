import SwiftUI
import UniformTypeIdentifiers
import MoReadCore

struct BookCharactersView: View {
    let bookID: UUID
    let onLocate: (SourcePassage) -> Void
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var companion: CompanionModel
    @State private var saved: BookCharacterGuide?
    @State private var checkpoint: BookCharactersCheckpoint?
    @State private var progressBounded = true
    @State private var loaded = false
    @State private var query = ""
    @State private var expanded: Set<String> = []
    @State private var plan: CharacterGenerationPlan?
    @State private var deleting = false
    @State private var message: String?
    private struct CardDraft: Identifiable {
        let guide: BookCharacterGuide
        let card: ExtractedCharacterCard
        var id: UUID { card.id }
    }
    @State private var extracted: CardDraft?
    private struct ProfileDraft: Identifiable {
        let id = UUID()
        let guide: BookCharacterGuide?
        let person: BookCharacter?
    }
    @State private var editing: ProfileDraft?
    private var job: KnowledgeJobKey { .init(bookID: bookID, chapter: nil) }
    private var busy: Bool { companion.knowledgeTasks[job] != nil }
    private var book: Book? { library.books.first { $0.id == bookID && !$0.removed && $0.hasBody } }
    private var displayed: [BookCharacter] { book.flatMap { saved?.displayedCharacters(in: $0) } ?? [] }
    private var sourceCurrent: Bool { book.map { saved?.visible(in: $0) == true } ?? false }
    private var visible: BookCharacterGuide? { sourceCurrent || !displayed.isEmpty ? saved : nil }
    private var unfinished: BookCharactersCheckpoint? {
        guard let book, let checkpoint, checkpoint.generationID != saved?.generationID,
              checkpoint.sourceRevision == MemoryBookScope.fingerprint(book.chapters.map(\.revision)) else { return nil }
        return checkpoint
    }
    var body: some View {
        List {
            Section {
                Button("新增人物") { editing = ProfileDraft(guide: saved, person: nil) }
                    .disabled(book == nil || library.maintenance).accessibilityIdentifier("characters-add")
                Picker("整理范围", selection: $progressBounded) {
                    Text("读到此处").tag(true)
                    Text("全书").tag(false)
                }.pickerStyle(.segmented).disabled(busy).accessibilityIdentifier("characters-scope")
                ModelAssignmentPicker(task: .knowledge, title: "整理模型").disabled(busy)
                if busy {
                    Button("停止提取", role: .destructive) { companion.stopKnowledge(job) }.accessibilityIdentifier("characters-stop")
                } else {
                    Button(unfinished != nil ? "继续提取" : visible == nil ? (progressBounded ? "提取读过的人物" : "提取全书人物") : (progressBounded ? "更新到当前进度" : "更新全书人物")) { preview() }
                        .disabled(book == nil).accessibilityIdentifier("characters-generate")
                }
                if let status = companion.knowledgeStates[job] { Text(status).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("characters-status") }
                if let unfinished, !busy { Text("已保存 \(unfinished.completedParts) 段提取进度，核对原文和模型后可复用。").font(.caption).foregroundStyle(.secondary) }
                if saved != nil, !sourceCurrent { Text("正文或已读范围已变化；手动资料保留，可重新提取原文资料。").foregroundStyle(.secondary) }
                if saved != nil || checkpoint != nil {
                    Button("删除人物资料", role: .destructive) { deleting = true }.disabled(busy).accessibilityIdentifier("characters-delete")
                }
            } footer: {
                Text(progressBounded ? "只发送已读正文，当前章截到阅读进度。核对过的分段会保留，更新时可复用；离开此页后继续提取。" : "全书整理会发送未读章节，资料可能涉及后续情节。开始前请核对范围与调用次数。")
            }
            if let message { Text(message).foregroundStyle(.red) }
            if let guide = visible {
                Section {
                    Text(!sourceCurrent || guide.scannedChapters == 0 ? "\(displayed.count) 位人物 · 手动整理" : guide.progressBounded ? "\(displayed.count) 位人物 · 覆盖已读的 \(guide.scannedChapters) 章" : "\(displayed.count) 位人物 · 全书 \(guide.scannedChapters) 章")
                        .accessibilityIdentifier("characters-summary")
                    if sourceCurrent { Text(guide.modelLabel).font(.caption).foregroundStyle(.secondary) }
                    HStack {
                        TextField("查找书中人物", text: $query).autocorrectionDisabled().submitLabel(.search).accessibilityIdentifier("characters-search")
                        if !query.isEmpty { Button("清除搜索", systemImage: "xmark.circle.fill") { query = "" }.labelStyle(.iconOnly).buttonStyle(.borderless) }
                    }
                }
                let people = displayed.filter { query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || [$0.name, $0.id].contains(where: { $0.localizedCaseInsensitiveContains(query.trimmingCharacters(in: .whitespacesAndNewlines)) }) }
                if people.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "未提取到人物" : "没有找到这个人物", systemImage: "person.text.rectangle", description: Text(query.isEmpty ? "本次扫描没有发现可核对的人物资料。" : "试试原文中的姓名或称呼。"))
                }
                ForEach(people) { person in
                    Section(person.name) {
                        Button("编辑人物") { editing = ProfileDraft(guide: guide, person: person) }.accessibilityIdentifier("characters-edit-" + person.id)
                        Button("提取为伴读角色卡") {
                            do {
                                guard !library.maintenance, let storage = library.store else { return }
                                library.flush()
                                let draft = try BookCharactersStore(library: storage, bookID: bookID).extractedCard(from: guide, named: person.name)
                                extracted = CardDraft(guide: guide, card: draft)
                            } catch { message = error.localizedDescription }
                        }.accessibilityIdentifier("characters-card-" + person.name)
                        if let description = person.manualDescription {
                            Text("手动整理").font(.caption).foregroundStyle(.secondary)
                            Text(description).lineLimit(expanded.contains(person.id) ? nil : 4).accessibilityIdentifier("characters-description-" + person.id)
                        }
                        if !person.evidence.isEmpty { Text("依据来自 \(Set(person.evidence.map(\.chapter)).count) 章").font(.caption).foregroundStyle(.secondary) }
                        ForEach(Array((expanded.contains(person.id) ? person.evidence : person.manualDescription == nil ? Array(person.evidence.prefix(1)) : []).enumerated()), id: \.offset) { index, evidence in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(evidence.fact.text)
                                Text("“\(evidence.fact.quote)”").font(.callout).foregroundStyle(.secondary)
                                Text(book?.chapters.first { $0.id == evidence.chapter }?.title ?? "第 \(evidence.chapter + 1) 章").font(.caption).foregroundStyle(.secondary)
                                Button("核对原文") { locate(guide, evidence: evidence) }.buttonStyle(.borderless).accessibilityIdentifier("characters-locate-\(person.name)-\(index)")
                            }.padding(.vertical, 6)
                        }
                        if person.evidence.count > 1 || person.manualDescription != nil {
                            Button(expanded.contains(person.id) ? "收起人物资料" : person.manualDescription != nil ? "展开资料与原文依据" : "展开其余 \(person.evidence.count - 1) 条资料") {
                                if expanded.contains(person.id) { expanded.remove(person.id) } else { expanded.insert(person.id) }
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView("书中人物，一处查看", systemImage: "person.text.rectangle", description: Text("从原文整理人物、身份与关系，每条资料保留原文依据。只合并相同姓名，保留最初介绍和近期事实。"))
            }
        }.navigationTitle("书中人物").scrollDismissesKeyboard(.interactively)
            .task { reload() }
            .onChange(of: library.recordsRevision) { _, _ in reload() }
            .sheet(item: $extracted) { draft in
                ExtractedCharacterEditor(guide: draft.guide, originalName: draft.card.name, draft: draft.card)
            }
            .sheet(item: $editing) { draft in
                BookCharacterEditor(bookID: bookID, expected: draft.guide, person: draft.person)
            }
            .sheet(item: $plan) { value in
                NavigationStack {
                    Form {
                        LabeledContent("书籍", value: value.source.bookTitle)
                        LabeledContent("整理范围", value: value.source.progressBounded ? "读到此处 · \(value.source.chapters.count) 章" : "全书 · \(value.source.chapters.count) 章")
                        LabeledContent("原文长度", value: "\(value.source.sourceCharacters) 字")
                        LabeledContent("模型", value: value.source.modelLabel)
                        LabeledContent("调用上限", value: "含纠错最多 \(value.source.maximumRequests) 次")
                        if value.source.resuming { Text("已保存 \(value.source.completedParts) 段进度，核对通过后会直接复用。") }
                        Text(value.source.progressBounded ? "将已读原文发送给所选 AI 服务商，按服务商规则计费。" : "将整本书发送给所选 AI 服务商，包括尚未读到的章节；人物资料可能涉及后续情节。按服务商规则计费。")
                        Text("已核对的分段按原文和模型复用。中途停止会保留分段进度，上次完整资料继续可用；全部完成后才替换。")
                        Button(value.source.resuming ? "继续提取" : value.source.progressBounded ? "提取到此处" : "提取全书") { companion.startCharacters(value, library: library); plan = nil }.accessibilityIdentifier("characters-confirm")
                    }.navigationTitle("确认人物提取")
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { plan = nil } } }
                }
            }
            .alert("删除人物资料？", isPresented: $deleting) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    guard !busy, !library.maintenance, let storage = library.store else { return }
                    defer { library.recordsRevision = UUID() }
                    do {
                        try BookCharactersStore(library: storage, bookID: bookID).delete()
                        companion.knowledgeStates.removeValue(forKey: job); query = ""; expanded = []
                    } catch { message = error.localizedDescription }
                }
            } message: { Text("删除这本书的人物资料、分段缓存和未完成的提取进度。") }
    }
    private func preview() {
        do { plan = try companion.previewCharacters(bookID: bookID, progressBounded: progressBounded, library: library); message = nil }
        catch { message = error.localizedDescription }
    }
    private func reload() {
        do {
            guard let storage = library.store else { return }
            let store = BookCharactersStore(library: storage, bookID: bookID)
            saved = try store.guide(); checkpoint = try store.checkpoint()
            if !loaded { progressBounded = saved?.progressBounded ?? true; loaded = true }
        } catch { message = error.localizedDescription }
    }
    private func locate(_ guide: BookCharacterGuide, evidence: CharacterEvidence) {
        do {
            guard !library.maintenance, let storage = library.store else { return }
            library.flush(); onLocate(try BookCharactersStore(library: storage, bookID: bookID).locate(guide, evidence: evidence))
        } catch { message = error.localizedDescription }
    }
}

private struct BookCharacterEditor: View {
    let bookID: UUID
    let expected: BookCharacterGuide?
    let originalIdentity: String?
    @State private var name: String
    @State private var description: String
    @State private var error: String?
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    init(bookID: UUID, expected: BookCharacterGuide?, person: BookCharacter?) {
        self.bookID = bookID; self.expected = expected; originalIdentity = person?.id
        _name = State(initialValue: person?.name ?? ""); _description = State(initialValue: person?.editableDescription ?? "")
    }
    var body: some View {
        NavigationStack {
            Form {
                TextField("姓名", text: $name).focused($focused).accessibilityIdentifier("character-profile-name")
                Section {
                    TextEditor(text: $description).frame(minHeight: 220).focused($focused).accessibilityLabel("人物资料")
                        .accessibilityIdentifier("character-profile-description")
                } footer: { Text("手写资料独立保存，重新提取会保留。原文依据仍由提取结果更新；改名后也可按原名查找。") }
                if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("character-profile-error") }
            }.navigationTitle(originalIdentity == nil ? "新增人物" : "编辑人物").scrollDismissesKeyboard(.interactively)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            do {
                                guard !library.maintenance, let storage = library.store else { throw MoReadError.invalid("书库忙碌，请稍后再试。") }
                                focused = false; library.flush()
                                try BookCharactersStore(library: storage, bookID: bookID).saveCharacter(expected: expected, originalIdentity: originalIdentity, name: name, description: description)
                                library.recordsRevision = UUID(); dismiss()
                            } catch { self.error = error.localizedDescription }
                        }.disabled(library.maintenance || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("character-profile-save")
                    }
                    ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完成") { focused = false } }
                }
        }
    }
}

private struct ExtractedCharacterEditor: View {
    let guide: BookCharacterGuide
    let originalName: String
    @State var draft: ExtractedCharacterCard
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var companion: CompanionModel
    @Environment(\.dismiss) private var dismiss
    @State private var document: ExtractedCharacterDocument?
    @State private var exporting = false
    @State private var message: String?
    @FocusState private var focused: Bool
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("姓名", text: $draft.name).focused($focused).accessibilityIdentifier("extracted-card-name")
                    TextEditor(text: $draft.description).frame(minHeight: 220).focused($focused)
                        .accessibilityLabel("人物资料").accessibilityIdentifier("extracted-card-description")
                } footer: {
                    Text("核对原文依据后保存，可补充性格和说话方式。角色资料会在伴读时发送给所选模型；完整人设始终随角色使用。")
                }
                Section {
                    Button("保存为伴读角色") {
                        do {
                            focused = false; try validateSource()
                            if companion.saveCard(try draft.characterCard()) { dismiss() }
                        } catch { message = error.localizedDescription }
                    }.accessibilityIdentifier("extracted-card-save")
                    Button("导出角色卡 JSON") {
                        do {
                            focused = false; try validateSource()
                            document = ExtractedCharacterDocument(data: try draft.json()); exporting = true
                        } catch { message = error.localizedDescription }
                    }.accessibilityIdentifier("extracted-card-export")
                }.disabled(library.maintenance || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let message { Text(message).font(.callout).accessibilityIdentifier("extracted-card-status") }
            }.navigationTitle("提取角色卡").scrollDismissesKeyboard(.interactively)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                    ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完成") { focused = false } }
                }
                .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "MoRead-角色卡.json") { result in
                    switch result {
                    case .success: message = "角色卡已导出，可在支持 SillyTavern 的应用中导入。"
                    case .failure(let error): message = "导出失败：" + error.localizedDescription
                    }
                }
        }
    }
    private func validateSource() throws {
        guard !library.maintenance, let storage = library.store else { throw MoReadError.invalid("书库忙碌，请稍后再试。") }
        library.flush()
        _ = try BookCharactersStore(library: storage, bookID: guide.bookID).extractedCard(from: guide, named: originalName)
    }
}

private struct ExtractedCharacterDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, data.count <= 4 * 1024 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
