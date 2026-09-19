import SwiftUI
import UIKit
import MoReadCore

struct ReaderView: View {
    let bookID: UUID
    @EnvironmentObject private var model: LibraryModel
    @EnvironmentObject private var companion: CompanionModel
    @EnvironmentObject private var speech: SpeechPlayer
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("reader.fontSize") private var fontSize = 21.0
    @AppStorage("reader.lineSpacing") private var lineSpacing = 10.0
    @AppStorage("reader.paper") private var paper = "paper"
    @State private var chapter: Chapter?
    @State private var requestedOffset = 0
    @State private var navigationID = UUID()
    @State private var sheet: ReaderSheet?
    @State private var selection: SourcePassage?
    @State private var note = ""
    @State private var style = "highlight"
    @State private var records = BookRecords()
    @State private var query = ""
    @State private var results: [SourcePassage] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var readingStarted: Date?
    @State private var chat: ChatDestination?
    @State private var chatSelection: SourcePassage?
    private var book: Book? { model.books.first { $0.id == bookID && !$0.removed } }
    private var paperColor: Color { paper == "night" ? Color(white: 0.10) : paper == "white" ? .white : Color(red: 0.97, green: 0.95, blue: 0.89) }
    enum ReaderSheet: String, Identifiable { case contents, typography, search, notes, speech; var id: String { rawValue } }

    var body: some View {
        Group {
            if let book {
                VStack(spacing: 0) {
                    if book.format == "epub" {
                        EPUBReader(book: book, fontSize: fontSize, lineSpacing: lineSpacing, paper: paper, annotations: records.annotations, speechLocation: speech.location, onLocation: { data in
                            var updated = self.book ?? book; updated.epubLocator = data; updated.lastOpened = Date(); model.update(updated)
                        }, onSelection: { passage in selection = passage; note = "" })
                    } else if let chapter {
                        TextReader(text: chapter.text, fontSize: fontSize, lineSpacing: lineSpacing, paper: UIColor(paperColor), night: paper == "night", offset: requestedOffset, navigationID: navigationID,
                                   annotations: records.annotations.filter { $0.passage.chapter == chapter.id },
                                   speechRange: speech.location.flatMap { $0.bookID == bookID && $0.chapter == chapter.id ? $0.range : nil },
                                   onPosition: { start, end in
                            guard var updated = self.book, self.chapter?.id == chapter.id else { return }
                            updated.record(position: .init(chapter: chapter.id, offset: start), visibleEnd: .init(chapter: chapter.id, offset: end))
                            model.update(updated)
                        }, onSelection: { range in
                            selection = SourcePassage(bookID: book.id, chapter: chapter, offset: range.location, text: (chapter.text as NSString).substring(with: range)); note = ""
                        })
                        HStack {
                            Button("上一章", systemImage: "chevron.left") { loadChapter(chapter.id - 1) }.disabled(chapter.id == 0)
                            Spacer()
                            Text("\(chapter.id + 1) / \(book.chapters.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Spacer()
                            Button("下一章", systemImage: "chevron.right") { loadChapter(chapter.id + 1) }.disabled(chapter.id + 1 >= book.chapters.count)
                        }.font(.subheadline).padding(.horizontal, 20).padding(.vertical, 10)
                    } else { ProgressView("正在打开…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                }.background(paperColor)
                    .navigationTitle(chapter?.title ?? book.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar(.hidden, for: .tabBar)
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) { Button("伴读", systemImage: "bubble.left.and.bubble.right") { openChat() } }
                        ToolbarItem(placement: .primaryAction) { Button("听书", systemImage: "headphones") { sheet = .speech } }
                        ToolbarItemGroup(placement: .bottomBar) {
                            Button("目录", systemImage: "list.bullet") { sheet = .contents }
                            Spacer()
                            Button("搜索", systemImage: "magnifyingglass") { sheet = .search }
                            Spacer()
                            Button("书签", systemImage: "bookmark") { addBookmark() }
                            Spacer()
                            Button("批注", systemImage: "pencil.and.list.clipboard") { sheet = .notes }
                            Spacer()
                            Button("排版", systemImage: "textformat.size") { sheet = .typography }
                        }
                    }
                    .task(id: bookID) {
                        model.perform { if let value = try model.store?.records(for: book) { records = value } }
                        if book.format == "txt" { loadChapter(book.position.chapter, offset: book.position.offset) }
                        readingStarted = Date()
                    }
                    .sheet(item: $sheet) { kind in readerSheet(kind, book: book) }
                    .sheet(item: $chat) { target in NavigationStack { CompanionChat(conversationID: target.id, selection: chatSelection) } }
                    .sheet(item: $selection) { passage in
                        NavigationStack {
                            Form {
                                Section("原文") { Text(passage.text).textSelection(.enabled) }
                                Section("我的笔记") { TextEditor(text: $note).frame(minHeight: 120).accessibilityLabel("笔记") }
                                Button("和角色聊这一段", systemImage: "bubble.left.and.bubble.right") {
                                    selection = nil
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { openChat(passage) }
                                }
                                Picker("标记样式", selection: $style) { Text("荧光").tag("highlight"); Text("下划线").tag("underline"); Text("波浪线").tag("wave") }
                            }.navigationTitle("记录这一段")
                                .toolbar {
                                    ToolbarItem(placement: .cancellationAction) { Button("取消") { selection = nil } }
                                    ToolbarItem(placement: .confirmationAction) { Button("保存") { saveAnnotation(passage) } }
                                }
                        }
                    }
            } else { ContentUnavailableView("书籍已移除", systemImage: "book.closed") }
        }
        .onDisappear { recordTime(); model.flush(); searchTask?.cancel() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshReadingTime() } else { recordTime(); model.flush() }
        }
        .onChange(of: sheet) { _, _ in refreshReadingTime() }
        .onChange(of: selection) { _, _ in refreshReadingTime() }
        .onChange(of: chat?.id) { _, _ in refreshReadingTime() }
        .onChange(of: speech.location) { _, location in
            guard let location, location.bookID == bookID, book?.format == "txt", chapter?.id != location.chapter else { return }
            loadChapter(location.chapter, offset: location.range.location)
        }
    }

    @ViewBuilder private func readerSheet(_ kind: ReaderSheet, book: Book) -> some View {
        NavigationStack {
            Group {
                switch kind {
                case .speech:
                    SpeechControls(book: book)
                case .contents:
                    List {
                        Section("章节") {
                            ForEach(book.chapters) { item in
                                Button(item.title) {
                                    if book.format == "txt" { loadChapter(item.id) }
                                    else { NotificationCenter.default.post(name: .epubJump, object: EPUBJump(bookID: book.id, chapter: item.id, offset: 0)) }
                                    sheet = nil
                                }.foregroundStyle(item.id == chapter?.id ? Color.accentColor : .primary)
                            }
                        }
                        Section("书签") {
                            ForEach(records.bookmarks) { bookmark in
                                Button(bookmark.label) {
                                    if book.format == "txt" { loadChapter(bookmark.position.chapter, offset: bookmark.position.offset) }
                                    else { NotificationCenter.default.post(name: .epubJump, object: EPUBJump(bookID: book.id, chapter: bookmark.position.chapter, offset: bookmark.position.offset, locator: bookmark.locator)) }
                                    sheet = nil
                                }
                            }.onDelete { offsets in records.bookmarks.remove(atOffsets: offsets); saveRecords() }
                        }
                    }
                case .typography:
                    Form {
                        Section("文字") {
                            LabeledContent("字号", value: "\(Int(fontSize))")
                            Slider(value: $fontSize, in: 14...36, step: 1).accessibilityLabel("字号")
                            LabeledContent("行距", value: "\(Int(lineSpacing))")
                            Slider(value: $lineSpacing, in: 0...24, step: 1).accessibilityLabel("行距")
                        }
                        Picker("纸张", selection: $paper) { Text("米白").tag("paper"); Text("纯白").tag("white"); Text("夜读").tag("night") }
                    }
                case .search:
                    List(results) { passage in
                        Button {
                            if book.format == "txt" { loadChapter(passage.chapter, offset: passage.offset) }
                            else { NotificationCenter.default.post(name: .epubJump, object: EPUBJump(bookID: book.id, chapter: passage.chapter, offset: passage.offset, locator: passage.epubLocator)) }
                            sheet = nil
                        } label: {
                            VStack(alignment: .leading, spacing: 8) { Text(book.chapters[passage.chapter].title).font(.caption).foregroundStyle(.secondary); Text(passage.text).lineLimit(4) }.foregroundStyle(.primary)
                        }
                    }.searchable(text: $query, prompt: "搜索全书原文")
                        .onChange(of: query) { _, value in search(value, book: book) }
                case .notes:
                    List {
                        if records.annotations.isEmpty { Text("长按正文，选择“批注”即可保存。").foregroundStyle(.secondary) }
                        ForEach(records.annotations) { annotation in
                            VStack(alignment: .leading, spacing: 10) { Text(annotation.passage.text).font(.callout); if !annotation.note.isEmpty { Text(annotation.note).foregroundStyle(.secondary) } }
                        }.onDelete { offsets in records.annotations.remove(atOffsets: offsets); saveRecords() }
                        if let markdown = try? model.store?.notesMarkdown(for: book) { ShareLink("导出笔记", item: markdown) }
                    }
                }
            }.navigationTitle(kind == .contents ? "目录与书签" : kind == .typography ? "阅读排版" : kind == .search ? "书内搜索" : kind == .speech ? "听书" : "批注")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { sheet = nil } } }
        }
    }
    private func loadChapter(_ index: Int, offset: Int = 0) {
        guard let book, book.chapters.indices.contains(index) else { return }
        model.perform {
            chapter = try model.store?.chapter(index, in: book)
            requestedOffset = offset; navigationID = UUID()
        }
    }
    private func openChat(_ passage: SourcePassage? = nil) {
        guard var book else { return }
        if let passage {
            book.readThrough = max(book.readThrough, ReadingPosition(chapter: passage.chapter, offset: passage.offset + passage.text.utf16.count))
            model.update(book, immediate: true)
        }
        chatSelection = passage
        if let id = companion.newConversation(book: book) { chat = ChatDestination(id: id) }
    }
    private func saveRecords() { guard let book else { return }; model.perform { try model.store?.saveRecords(records, for: book) } }
    private func addBookmark() {
        guard let book else { return }
        guard !records.bookmarks.contains(where: { $0.position == book.position && $0.locator == book.epubLocator }) else { return }
        records.bookmarks.append(Bookmark(position: book.position, label: chapter?.title ?? book.title, locator: book.epubLocator)); saveRecords()
    }
    private func saveAnnotation(_ passage: SourcePassage) {
        records.annotations.append(Annotation(passage: passage, note: note, style: style)); saveRecords(); selection = nil
    }
    private func recordTime() {
        guard let start = readingStarted else { return }
        readingStarted = nil
        let end = Date()
        let calendar = Calendar.current
        var cursor = start
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.dateFormat = "yyyy-MM-dd"
        while cursor < end {
            guard let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: cursor)) else { break }
            let sliceEnd = min(end, next)
            records.readingSeconds[formatter.string(from: cursor), default: 0] += sliceEnd.timeIntervalSince(cursor)
            cursor = sliceEnd
        }
        saveRecords()
    }
    private func refreshReadingTime() {
        if sheet == nil, selection == nil, chat == nil, scenePhase == .active {
            if readingStarted == nil { readingStarted = Date() }
        } else { recordTime() }
    }
    private func search(_ value: String, book: Book) {
        searchTask?.cancel(); results = []
        guard !value.isEmpty, let root = model.store?.root else { return }
        searchTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(300))
                let found = try await Task.detached {
                    let store = try LibraryStore(root: root)
                    var found: [SourcePassage] = []
                    for index in book.chapters.indices {
                        try Task.checkCancellation()
                        let chapter = try store.chapter(index, in: book)
                        found += BookSearch.find(value, in: chapter, bookID: book.id, scope: .wholeBook, limit: 100 - found.count)
                        if found.count >= 100 { break }
                    }
                    return found
                }.value
                try Task.checkCancellation(); results = found
            } catch is CancellationError {} catch { model.error = error.localizedDescription }
        }
    }
}

struct TextReader: UIViewRepresentable {
    let text: String
    let fontSize: Double
    let lineSpacing: Double
    let paper: UIColor
    let night: Bool
    let offset: Int
    let navigationID: UUID
    let annotations: [Annotation]
    let speechRange: NSRange?
    let onPosition: (Int, Int) -> Void
    let onSelection: (NSRange) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let storage = NSTextStorage()
        let manager = AnnotationLayoutManager()
        let container = NSTextContainer(size: .zero)
        container.widthTracksTextView = true
        manager.addTextContainer(container); storage.addLayoutManager(manager)
        let view = UITextView(frame: .zero, textContainer: container)
        view.isEditable = false; view.isSelectable = true
        view.textContainerInset = UIEdgeInsets(top: 24, left: 22, bottom: 30, right: 22)
        view.delegate = context.coordinator
        view.accessibilityIdentifier = "reader-text"
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        let coordinator = context.coordinator
        let previous = coordinator.parent
        let navigationChanged = coordinator.navigationID != navigationID
        let preservedOffset = coordinator.lastPosition
        let needsLayout = view.text != text || previous.fontSize != fontSize || previous.lineSpacing != lineSpacing || previous.night != night || previous.annotations != annotations
        coordinator.parent = self
        view.backgroundColor = paper
        if needsLayout {
            let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = lineSpacing; paragraph.paragraphSpacing = 12
            let value = NSMutableAttributedString(string: text, attributes: [.font: UIFont.systemFont(ofSize: fontSize), .foregroundColor: night ? UIColor(white: 0.88, alpha: 1) : UIColor(white: 0.16, alpha: 1), .paragraphStyle: paragraph])
            for annotation in annotations {
                let range = NSRange(location: annotation.passage.offset, length: annotation.passage.text.utf16.count)
                guard range.location >= 0, range.location <= value.length, range.length <= value.length - range.location else { continue }
                if annotation.style == "highlight" { value.addAttribute(.backgroundColor, value: UIColor.systemYellow.withAlphaComponent(0.28), range: range) }
                else { value.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: UIColor.systemOrange], range: range) }
                if annotation.style == "wave" { value.addAttribute(AnnotationLayoutManager.waveKey, value: true, range: range) }
            }
            view.attributedText = value
            coordinator.baseText = NSAttributedString(attributedString: value)
        }
        if previous.speechRange != speechRange || needsLayout {
            if !needsLayout, let old = previous.speechRange, old.location >= 0, NSMaxRange(old) <= coordinator.baseText.length {
                coordinator.baseText.enumerateAttributes(in: old) { attributes, range, _ in view.textStorage.setAttributes(attributes, range: range) }
            }
            if let speechRange, speechRange.location >= 0, NSMaxRange(speechRange) <= view.textStorage.length {
                view.textStorage.addAttribute(.backgroundColor, value: UIColor.systemTeal.withAlphaComponent(0.3), range: speechRange)
                view.scrollRangeToVisible(speechRange)
            }
        }
        if navigationChanged || needsLayout {
            coordinator.navigationID = navigationID
            DispatchQueue.main.async {
                guard coordinator.navigationID == self.navigationID else { return }
                view.layoutIfNeeded()
                let safe = TextBoundary.floor(navigationChanged ? offset : preservedOffset, in: text)
                view.scrollRangeToVisible(NSRange(location: safe, length: safe < text.utf16.count ? 1 : 0))
                coordinator.report(view)
            }
        }
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: TextReader
        var navigationID: UUID?
        var lastPosition = 0
        var baseText = NSAttributedString(string: "")
        init(_ parent: TextReader) { self.parent = parent }
        func scrollViewDidScroll(_ scrollView: UIScrollView) { if let view = scrollView as? UITextView { report(view) } }
        func report(_ view: UITextView) {
            guard view.bounds.height > 0, !view.text.isEmpty else { return }
            let rect = CGRect(x: 0, y: max(0, view.contentOffset.y - view.textContainerInset.top), width: view.bounds.width - view.textContainerInset.left - view.textContainerInset.right, height: view.bounds.height - view.textContainerInset.bottom)
            let glyphs = view.layoutManager.glyphRange(forBoundingRect: rect, in: view.textContainer)
            let range = view.layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let start = TextBoundary.floor(range.location, in: parent.text)
            let end = TextBoundary.floor(range.location + range.length, in: parent.text)
            lastPosition = start
            let currentID = navigationID
            let callback = parent.onPosition
            DispatchQueue.main.async { if self.navigationID == currentID { callback(start, end) } }
        }
        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard range.length > 0 else { return nil }
            let annotation = UIAction(title: "批注", image: UIImage(systemName: "pencil")) { [weak self] _ in self?.parent.onSelection(range) }
            return UIMenu(children: suggestedActions + [annotation])
        }
    }
}

final class AnnotationLayoutManager: NSLayoutManager {
    static let waveKey = NSAttributedString.Key("MoReadWaveUnderline")
    override func drawUnderline(forGlyphRange glyphRange: NSRange, underlineType underlineVal: NSUnderlineStyle, baselineOffset: CGFloat, lineFragmentRect lineRect: CGRect, lineFragmentGlyphRange lineGlyphRange: NSRange, containerOrigin: CGPoint) {
        let index = characterIndexForGlyph(at: glyphRange.location)
        guard let storage = textStorage, index < storage.length, storage.attribute(Self.waveKey, at: index, effectiveRange: nil) as? Bool == true,
              let container = textContainer(forGlyphAt: glyphRange.location, effectiveRange: nil) else {
            super.drawUnderline(forGlyphRange: glyphRange, underlineType: underlineVal, baselineOffset: baselineOffset, lineFragmentRect: lineRect, lineFragmentGlyphRange: lineGlyphRange, containerOrigin: containerOrigin)
            return
        }
        let bounds = boundingRect(forGlyphRange: glyphRange, in: container)
        let start = bounds.minX + containerOrigin.x
        let end = bounds.maxX + containerOrigin.x
        let y = lineRect.minY + location(forGlyphAt: glyphRange.location).y + containerOrigin.y + 3
        let path = UIBezierPath(); path.lineWidth = 1.25
        path.move(to: CGPoint(x: start, y: y))
        var x = start
        while x <= end { path.addLine(to: CGPoint(x: x, y: y + sin((x - start) * .pi / 3) * 1.25)); x += 0.75 }
        (storage.attribute(.underlineColor, at: index, effectiveRange: nil) as? UIColor ?? .systemOrange).setStroke()
        path.stroke()
    }
}
