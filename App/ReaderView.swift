import SwiftUI
import UIKit
import MoReadCore

struct ReaderView: View {
    let bookID: UUID
    var initialPassage: SourcePassage? = nil
    var initialPassageScope: ReadingScope? = nil
    @EnvironmentObject private var model: LibraryModel
    @EnvironmentObject private var companion: CompanionModel
    @EnvironmentObject private var speech: SpeechPlayer
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("reader.fontSize") private var fontSize = 21.0
    @AppStorage("reader.lineSpacing") private var lineSpacing = 10.0
    @AppStorage("reader.paper") private var paper = "paper"
    @AppStorage("reader.pageMode") private var pageMode = "scroll"
    @AppStorage("reader.typography") private var typographyData = Data()
    private var typography: ReaderTypography { ReaderTypography(data: typographyData) }
    @AppStorage("reader.autoRead") private var autoReadData = Data()
    @StateObject private var autoRead = AutoReadSession()
    @State private var pendingAutoRead: AutoReadSettings?
    @State private var immersive = false
    @State private var chapter: Chapter?
    @State private var translatedText = TranslatedText(source: "")
    @State private var wordGlosses: [String: DictionaryGloss] = [:]
    @State private var visiblePage: SourcePassage?
    @State private var selectionIsTranslation = false
    @State private var requestedOffset = 0
    @State private var navigationID = UUID()
    @State private var sheet: ReaderSheet?
    @State private var dictionaryWord = ""
    @State private var dictionarySource: SourcePassage?
    @State private var selection: SourcePassage?
    @AppStorage("reader.tapZones") private var tapZonesData = Data()
    private var tapZones: ReaderTapZones? { ReaderTapZones(data: tapZonesData) }
    @State private var actionMessage: String?
    @State private var bookmarkMessage: String?
    @State private var note = ""
    @State private var style = "highlight"
    @State private var records = BookRecords()
    @State private var query = ""
    @State private var results: [SourcePassage] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var readingStarted: Date?
    @State private var chat: ChatDestination?
    @State private var chatSelection: SourcePassage?
    @State private var opened = false
    @State private var initialSourceError: String?
    @State private var didLocateEPUB = false
    private var book: Book? { model.books.first { $0.id == bookID && !$0.removed } }
    private var completedChapter: Int? {
        guard let book else { return nil }
        return book.chapters.indices.last { $0 <= book.position.chapter && ReadingPosition(chapter: $0, offset: book.chapters[$0].length) <= book.readThrough }
    }
    private var paperColor: Color { (paper == "custom" || paper == "image") ? Color(rgb: typography.backgroundRGB ?? 0xF7F2E3) : paper == "night" ? Color(white: 0.10) : paper == "white" ? .white : Color(red: 0.97, green: 0.95, blue: 0.89) }
    private var ink: UIColor { (paper == "custom" || paper == "image") ? UIColor(Color(rgb: typography.textRGB ?? 0x292929)) : paper == "night" ? UIColor(white: 0.88, alpha: 1) : UIColor(white: 0.16, alpha: 1) }
    enum ReaderSheet: String, Identifiable { case contents, bookmarks, typography, search, notes, speech, autoRead, dictionary, englishLearning; var id: String { rawValue } }

    private var readingScreen: some View {
        Group {
            if let initialSourceError {
                ContentUnavailableView("无法打开原文", systemImage: "book.closed", description: Text(initialSourceError))
            } else if let book {
                readerContent(book: book).background(paperColor)
                    .navigationTitle(chapter?.title ?? book.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar(.hidden, for: .tabBar)
                    .toolbar(immersive ? .hidden : .visible, for: .navigationBar, .bottomBar)
                    .statusBarHidden(immersive)
                    .persistentSystemOverlays(immersive ? .hidden : .automatic)
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) { Button("自动阅读", systemImage: "play.rectangle") { sheet = .autoRead }.accessibilityIdentifier("auto-read-open") }
                        ToolbarItem(placement: .primaryAction) { Button("伴读", systemImage: "bubble.left.and.bubble.right") { openChat() } }
                        ToolbarItem(placement: .primaryAction) { Button("听书", systemImage: "headphones") { sheet = .speech } }
                        ToolbarItemGroup(placement: .bottomBar) {
                            Button("目录", systemImage: "list.bullet") { sheet = .contents }
                            Spacer()
                            Button("搜索", systemImage: "magnifyingglass") { sheet = .search }
                            Spacer()
                            Button("书签", systemImage: "bookmark") { bookmarkMessage = nil; sheet = .bookmarks }
                            Spacer()
                            Button("批注", systemImage: "pencil.and.list.clipboard") { sheet = .notes }
                            Spacer()
                            Button("排版", systemImage: "textformat.size") { sheet = .typography }
                        }
                    }
                    .task(id: bookID) {
                        model.perform { wordGlosses = EnglishReading.unlearned(try model.vocabulary?.words() ?? []) }
                        model.perform { if let value = try model.store?.records(for: book) { records = value } }
                        if !opened {
                            opened = true
                            do {
                                if let initialPassage {
                                    guard initialPassage.bookID == bookID, let source = try model.store?.chapter(initialPassage.chapter, in: book),
                                          initialPassage.isValid(in: source, scope: initialPassageScope ?? ReadingScope(through: book.readThrough)) else { throw MoReadError.invalid("原文或已读范围已经变化，请返回后重新打开。") }
                                    if book.format == "txt" { loadChapter(initialPassage.chapter, offset: initialPassage.offset) }
                                } else if book.format == "txt" { loadChapter(book.position.chapter, offset: book.position.offset) }
                            } catch { initialSourceError = error.localizedDescription; return }
                        }
                        refreshReadingTime()
                        companion.setAnnotationReader(bookID, library: model)
                    }
                    .sheet(item: $sheet, onDismiss: startPendingAutoRead) { kind in readerSheet(kind, book: book) }
                    .sheet(item: $chat) { target in NavigationStack { CompanionChat(conversationID: target.id, selection: chatSelection) } }
                    .sheet(item: $selection) { passage in selectionSheet(passage: passage) }
            } else { ContentUnavailableView("书籍已移除", systemImage: "book.closed") }
        }
    }

    private var observedReader: some View {
        readingScreen
        .onChange(of: completedChapter) { _, _ in companion.generateAnnotations(bookID: bookID, library: model) }
        .onChange(of: companion.settings.proactive) { _, _ in companion.generateAnnotations(bookID: bookID, library: model) }
        .onChange(of: book?.chapters.map(\.revision)) { _, _ in
            if let book, book.format == "txt" { loadChapter(book.position.chapter, offset: book.position.offset) }
        }
        .onChange(of: model.recordsRevision) { _, _ in
            if let book { model.perform { if let value = try model.store?.records(for: book) { records = value }; refreshTranslations() } }
        }
        .onChange(of: model.vocabularyRevision) { _, _ in model.perform { wordGlosses = EnglishReading.unlearned(try model.vocabulary?.words() ?? []) } }
    }

    var body: some View {
        observedReader
        .overlay { autoReadOverlay }
        .overlay(alignment: .bottom) {
            if let actionMessage {
                Text(actionMessage).font(.callout).padding(12).background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 20).allowsHitTesting(false).accessibilityIdentifier("reader-action-message")
                    .task(id: actionMessage) {
                        do { try await Task.sleep(for: .seconds(3)); self.actionMessage = nil } catch {}
                    }
            }
        }
        .onDisappear { autoRead.stop(); companion.setAnnotationReader(nil, library: model); recordTime(); model.flush(); searchTask?.cancel() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshReadingTime(); companion.setAnnotationReader(bookID, library: model) } else { autoRead.pause("离开阅读页后已暂停"); companion.setAnnotationReader(nil, library: model); recordTime(); model.flush() }
        }
        .onChange(of: sheet) { _, value in
            if value != nil { autoRead.pause("操作面板打开，已暂停") }
            refreshReadingTime()
            if value == .contents, book?.format == "epub" { NotificationCenter.default.post(name: .epubCapturePage, object: bookID) }
        }
        .onChange(of: selection) { _, value in if value != nil { autoRead.pause("操作面板打开，已暂停") }; refreshReadingTime() }
        .onChange(of: chat?.id) { _, value in if value != nil { autoRead.pause("操作面板打开，已暂停") }; refreshReadingTime() }
        .onChange(of: speech.isPlaying || speech.isPreparing) { _, active in if active { autoRead.pause("听书或语音播放期间暂停") } }
        .onChange(of: typographyData) { _, _ in autoRead.pause("排版改变，已暂停") }
        .onChange(of: fontSize) { _, _ in autoRead.pause("排版改变，已暂停") }
        .onChange(of: lineSpacing) { _, _ in autoRead.pause("排版改变，已暂停") }
        .onChange(of: pageMode) { _, _ in autoRead.pause("排版改变，已暂停") }
        .onChange(of: speech.location) { _, location in
            guard let location, location.bookID == bookID, book?.format == "txt", chapter?.id != location.chapter else { return }
            loadChapter(location.chapter, offset: location.range.location)
        }
    }

    private func startPendingAutoRead() {
        guard let settings = pendingAutoRead else { return }
        pendingAutoRead = nil
        guard scenePhase == .active, selection == nil, chat == nil, !speech.isPlaying, !speech.isPreparing else { return }
        autoRead.start(settings)
    }
    @ViewBuilder private var autoReadOverlay: some View {
        if autoRead.phase != .off {
            GeometryReader { geometry in
                if autoRead.settings.mode == .scroll, autoRead.settings.showGuide {
                    Rectangle().fill(Color.accentColor.opacity(0.5)).frame(height: 1)
                        .padding(.horizontal, 20).position(x: geometry.size.width / 2, y: geometry.size.height * 0.36)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                VStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Text(autoRead.label).font(.caption).accessibilityIdentifier("auto-read-status")
                        HStack(spacing: 20) {
                        Button(autoRead.engaged ? "暂停" : "继续") {
                            if autoRead.engaged { autoRead.pause() }
                            else if !speech.isPlaying, !speech.isPreparing, scenePhase == .active {
                                var settings = autoRead.settings
                                let scrolling = book?.format == "epub" ? (typography.epubScroll ?? false) : pageMode == "scroll"
                                settings.mode = scrolling ? .scroll : .page
                                autoReadData = settings.encoded(); autoRead.start(settings)
                            }
                        }.disabled(!autoRead.engaged && (speech.isPlaying || speech.isPreparing)).accessibilityIdentifier("auto-read-toggle")
                        Button("设置") { sheet = .autoRead }.accessibilityIdentifier("auto-read-settings")
                        Button("退出") { autoRead.stop() }.accessibilityIdentifier("auto-read-stop")
                        }
                    }.font(.subheadline).padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .padding(.horizontal, 12).padding(.bottom, immersive ? 12 : (book?.format == "txt" ? 112 : 20))
                }.frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder private func readerSheet(_ kind: ReaderSheet, book: Book) -> some View {
        NavigationStack {
            Group {
                switch kind {
                case .englishLearning:
                    EnglishReadingView(value: Binding(get: { typography }, set: { typographyData = $0.encoded() }))
                case .dictionary:
                    DictionaryLookupView(word: dictionaryWord, source: dictionarySource)
                case .autoRead:
                    AutoReadSettingsView(settings: AutoReadSettings(data: autoReadData), speechActive: speech.isPlaying || speech.isPreparing) { settings in
                        autoReadData = settings.encoded()
                        if book.format == "epub" {
                            var value = typography; value.epubScroll = settings.mode == .scroll; typographyData = value.encoded()
                        } else {
                            requestedOffset = self.book?.position.offset ?? 0; navigationID = UUID()
                            if settings.mode == .scroll { pageMode = "scroll" }
                            else if pageMode == "scroll" { pageMode = "slide" }
                        }
                        pendingAutoRead = settings; sheet = nil
                    }
                case .speech:
                    SpeechControls(book: book)
                case .contents:
                    List {
                        NavigationLink("查字词") { DictionaryLookupView() }
                        NavigationLink("生词本") { VocabularyView() }
                        NavigationLink("书籍封面") { BookCoverEditor(bookID: bookID) }
                        if book.format == "txt" { NavigationLink("正文清理") { TextCleanupView(bookID: bookID) }.accessibilityIdentifier("cleanup-open") }
                        NavigationLink("插图廊") { IllustrationGallery(bookID: bookID) }
                        NavigationLink("中英对照") { ParagraphTranslationView(bookID: bookID, chapter: chapter?.id ?? book.position.chapter) }
                        if let visiblePage {
                            NavigationLink("翻译当前页") { ParagraphTranslationView(bookID: bookID, chapter: visiblePage.chapter, range: NSRange(location: visiblePage.offset, length: visiblePage.text.utf16.count), sourceRevision: visiblePage.revision, currentPage: true) }
                        }
                        NavigationLink("书中人物") {
                            BookCharactersView(bookID: book.id) { passage in
                                if book.format == "txt" { loadChapter(passage.chapter, offset: passage.offset) }
                                else { NotificationCenter.default.post(name: .epubJump, object: EPUBJump(bookID: book.id, chapter: passage.chapter, offset: passage.offset)) }
                                sheet = nil
                            }
                        }
                        NavigationLink("章节提纲") {
                            ChapterKnowledgeView(bookID: book.id) { passage in
                                if book.format == "txt" { loadChapter(passage.chapter, offset: passage.offset) }
                                else { NotificationCenter.default.post(name: .epubJump, object: EPUBJump(bookID: book.id, chapter: passage.chapter, offset: passage.offset)) }
                                sheet = nil
                            }
                        }
                        Section("章节") {
                            ForEach(book.chapters) { item in
                                Button(item.title) {
                                    if book.format == "txt" { loadChapter(item.id) }
                                    else { NotificationCenter.default.post(name: .epubJump, object: EPUBJump(bookID: book.id, chapter: item.id, offset: 0)) }
                                    sheet = nil
                                }.foregroundStyle(item.id == chapter?.id ? Color.accentColor : .primary)
                            }
                        }
                        bookmarkList(book: book)
                    }
                case .bookmarks:
                    List {
                        Button("添加当前位置书签", systemImage: "bookmark.badge.plus") { addBookmark() }
                        if let bookmarkMessage { Text(bookmarkMessage).foregroundStyle(.secondary) }
                        bookmarkList(book: book)
                    }
                case .typography:
                    Form {
                        Button("进入沉浸阅读", systemImage: "arrow.up.left.and.arrow.down.right") { sheet = nil; immersive = true }.accessibilityIdentifier("enter-immersive")
                        NavigationLink("操作区域") { ReaderTapZonesView() }
                        Text(tapZones == nil ? "轻点正文中间可显示或收起阅读工具。" : "点按已设定的菜单区域可显示或收起阅读工具。").font(.caption).foregroundStyle(.secondary)
                        if book.format == "txt" {
                            Picker("翻页方式", selection: Binding(get: { pageMode }, set: { value in
                                requestedOffset = self.book?.position.offset ?? 0; navigationID = UUID(); pageMode = value
                            })) {
                                ForEach(ReaderPageMode.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                            }.accessibilityIdentifier("reader-page-mode")
                        }
                        if book.format == "epub" {
                            Picker("翻页方式", selection: Binding(get: { typography.epubScroll ?? false }, set: { enabled in
                                var value = typography; value.epubScroll = enabled; typographyData = value.encoded()
                            })) { Text("左右翻页").tag(false); Text("上下滚动").tag(true) }.accessibilityIdentifier("epub-page-mode")
                        }
                        NavigationLink("字体与段落") { ReaderTypographyView(value: Binding(get: { typography }, set: { typographyData = $0.encoded() }), isEPUB: book.format == "epub") }
                        NavigationLink("阅读辅助") { EnglishReadingView(value: Binding(get: { typography }, set: { typographyData = $0.encoded() })) }
                        Section("文字") {
                            Stepper(value: $fontSize, in: 14...36, step: 1) { LabeledContent("字号", value: "\(Int(fontSize))") }.accessibilityIdentifier("reader-font-size-stepper")
                            Slider(value: $fontSize, in: 14...36, step: 1).accessibilityLabel("字号")
                            LabeledContent("行距", value: "\(Int(lineSpacing))")
                            Slider(value: $lineSpacing, in: 0...24, step: 1).accessibilityLabel("行距")
                        }
                        Picker("纸张", selection: $paper) { Text("米白").tag("paper"); Text("纯白").tag("white"); Text("夜读").tag("night"); Text("自定义颜色").tag("custom"); Text("背景图片").tag("image") }
                        NavigationLink("阅读背景图片") { ReaderBackgroundView() }
                        if paper == "custom" || paper == "image" {
                            ColorPicker("阅读背景", selection: Binding(get: { paperColor }, set: { color in
                                var value = typography; value.backgroundRGB = color.savedRGB; typographyData = value.encoded()
                            }), supportsOpacity: false)
                            ColorPicker("正文颜色", selection: Binding(get: { Color(ink) }, set: { color in
                                var value = typography; value.textRGB = color.savedRGB; typographyData = value.encoded()
                            }), supportsOpacity: false)
                        }
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
                        NavigationLink("读书笔记与梗概") { ReadingNotesView(bookID: bookID) }
                        NavigationLink("随读段评设置") { ProactiveSettingsView() }
                        if companion.annotationBookID == bookID, let status = companion.annotationStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
                        if records.annotations.isEmpty { Text("长按正文，选择“批注”即可保存。").foregroundStyle(.secondary) }
                        ForEach(records.annotations) { annotation in
                            VStack(alignment: .leading, spacing: 10) { if annotation.characterName != nil { Text(annotation.authorLabel).font(.caption).foregroundStyle(.secondary) }; Text(annotation.passage.text).font(.callout); if !annotation.note.isEmpty { Text(annotation.note).foregroundStyle(.secondary) } }
                        }.onDelete { offsets in
                            let ids = Set(offsets.map { records.annotations[$0].id })
                            changeRecords { $0.annotations.removeAll { ids.contains($0.id) } }
                        }
                        if let markdown = try? model.store?.notesMarkdown(for: book) { ShareLink("导出笔记", item: markdown) }
                    }
                }
            }.navigationTitle(kind == .englishLearning ? "阅读辅助" : kind == .dictionary ? "本地词典" : kind == .contents ? "目录与书签" : kind == .bookmarks ? "书签" : kind == .typography ? "阅读排版" : kind == .search ? "书内搜索" : kind == .speech ? "听书" : "批注")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { sheet = nil } } }
        }
    }
    @ViewBuilder private func readerContent(book: Book) -> some View {
        VStack(spacing: 0) {
            if book.format == "epub" {
                EPUBReader(autoRead: autoRead, isReading: sheet == nil && selection == nil && chat == nil && scenePhase == .active, onBookmark: addBookmark, tapZones: tapZones, onTapAction: performTapAction, book: book, initialPassage: didLocateEPUB ? nil : initialPassage, initialPassageScope: initialPassageScope, fontSize: fontSize, lineSpacing: lineSpacing, typography: typography, paper: paper, annotations: records.annotations, speechLocation: speech.location, onToggleControls: { immersive.toggle() }, onLocation: { data in
                    didLocateEPUB = true
                    var updated = self.book ?? book; updated.epubLocator = data; updated.lastOpened = Date(); model.update(updated)
                }, onSelection: { passage, translated in selectionIsTranslation = translated; selection = passage; note = "" }, onVisiblePage: { visiblePage = $0 }, onDictionary: { word, source in dictionaryWord = word; dictionarySource = source; sheet = .dictionary }).id("\(typography.customFontID?.uuidString ?? "")-\(model.readingBackgroundID)-\(paper == "image")-\(typography.backgroundOpacity ?? 0.25)-\(typography.backgroundRGB ?? 0xF7F2E3)-\(typography.epubScroll ?? false)")
            } else if let chapter {
                let content = textContent(book: book, chapter: chapter)
                if (ReaderPageMode(rawValue: pageMode) ?? .scroll) == .scroll {
                    ContinuousTextReader(bookID: bookID, chapterCount: book.chapters.count, currentChapter: chapter.id, content: content, revision: model.recordsRevision, chapterContent: { index in
                        guard book.chapters.indices.contains(index), let store = model.store else { return nil }
                        do {
                            let source = index == self.chapter?.id ? self.chapter! : try store.chapter(index, in: book)
                            let rows = try ParagraphTranslationStore(library: store, bookID: bookID).load(chapter: index)
                            let presentation = TranslatedText(source: source.text, translations: rows, visible: records.translationsVisible ?? true)
                            return (source, textContent(book: book, chapter: source, presentation: presentation))
                        } catch {
                            DispatchQueue.main.async { model.error = error.localizedDescription }
                            return nil
                        }
                    }, onRead: { position, end, passage in
                        guard sheet == nil, selection == nil, chat == nil, scenePhase == .active, var updated = self.book else { return }
                        if self.chapter?.id != position.chapter {
                            model.perform { self.chapter = try model.store?.chapter(position.chapter, in: updated); refreshTranslations() }
                        }
                        updated.record(position: position, visibleEnd: end); model.update(updated)
                        visiblePage = passage
                    })
                } else {
                    PagedTextReader(content: content, mode: ReaderPageMode(rawValue: pageMode) ?? .slide,
                                    hasPreviousChapter: chapter.id > 0, hasNextChapter: chapter.id + 1 < book.chapters.count,
                                    onChapter: { direction in loadChapter(chapter.id + direction, offset: direction < 0 ? Int.max : 0) })
                        .id(pageMode)
                }
                if !immersive { HStack {
                    Button("上一章", systemImage: "chevron.left") { loadChapter(chapter.id - 1) }.disabled(chapter.id == 0)
                    Spacer()
                    Text("\(chapter.id + 1) / \(book.chapters.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Button("下一章", systemImage: "chevron.right") { loadChapter(chapter.id + 1) }.disabled(chapter.id + 1 >= book.chapters.count)
                }.font(.subheadline).padding(.horizontal, 20).padding(.vertical, 10) }
            } else { ProgressView("正在打开…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
    }

    private func selectionSheet(passage: SourcePassage) -> some View {
        NavigationStack {
            if selectionIsTranslation {
                ParagraphTranslationView(bookID: bookID, chapter: passage.chapter, range: NSRange(location: passage.offset, length: passage.text.utf16.count), sourceRevision: passage.revision)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { selection = nil } } }
            } else {
                Form {
                    Section("原文") { Text(passage.text).textSelection(.enabled) }
                    NavigationLink("查字词") { DictionaryLookupView(word: passage.text, source: passage) }
                    NavigationLink("本段对照") { ParagraphTranslationView(bookID: bookID, chapter: passage.chapter, range: NSRange(location: passage.offset, length: passage.text.utf16.count), sourceRevision: passage.revision) }
                    NavigationLink("为这一段生成插图") { IllustrationGenerator(bookID: bookID, source: passage) }
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
    }

    private func textContent(book: Book, chapter: Chapter, presentation: TranslatedText? = nil) -> TextReader {
        TextReader(autoRead: autoRead, onAutoNext: {
            guard chapter.id + 1 < book.chapters.count else { return false }
            loadChapter(chapter.id + 1, automatic: true); return true
        }, presentation: presentation ?? translatedText, font: model.customFont(typography.customFontID, size: fontSize) ?? typography.uiFont(size: fontSize), fontSize: fontSize, lineSpacing: lineSpacing, typography: typography, paper: UIColor(paperColor), backgroundImage: paper == "image" ? model.readingBackground : nil, ink: ink, night: paper == "night", offset: requestedOffset, navigationID: navigationID,
                   annotations: records.annotations.filter { $0.passage.bookID == bookID && $0.passage.isValid(in: chapter, scope: .wholeBook) }, wordGlosses: wordGlosses,
                   speechRange: speech.location.flatMap { $0.bookID == bookID && $0.chapter == chapter.id ? $0.range : nil },
                   immersive: immersive, tapZones: tapZones, onTapAction: performTapAction, onToggleControls: { immersive.toggle() }, onBookmark: addBookmark,
                   isReading: sheet == nil && selection == nil && chat == nil && scenePhase == .active,
                   onPosition: { start, visible in
            guard sheet == nil, selection == nil, chat == nil, scenePhase == .active,
                  var updated = self.book, self.chapter?.id == chapter.id else { return }
            updated.record(position: .init(chapter: chapter.id, offset: start), visibleEnd: .init(chapter: chapter.id, offset: NSMaxRange(visible)))
            model.update(updated)
            if visible.length > 0 { visiblePage = SourcePassage(bookID: book.id, chapter: chapter, offset: visible.location, text: (chapter.text as NSString).substring(with: visible)) }
        }, onSelection: { range in
            selectionIsTranslation = false
            selection = SourcePassage(bookID: book.id, chapter: chapter, offset: range.location, text: (chapter.text as NSString).substring(with: range)); note = ""
        }, onTranslation: { range in
            selectionIsTranslation = true
            selection = SourcePassage(bookID: book.id, chapter: chapter, offset: range.location, text: (chapter.text as NSString).substring(with: range))
        }, onDictionary: { word, range in
            dictionaryWord = word
            dictionarySource = SourcePassage(bookID: book.id, chapter: chapter, offset: range.location, text: (chapter.text as NSString).substring(with: range))
            sheet = .dictionary
        })
    }
    private func loadChapter(_ index: Int, offset: Int = 0, automatic: Bool = false) {
        if !automatic { autoRead.pause("阅读位置改变，已暂停") }
        guard let book, book.chapters.indices.contains(index) else { return }
        model.perform {
            chapter = try model.store?.chapter(index, in: book)
            requestedOffset = offset; navigationID = UUID(); visiblePage = nil
            refreshTranslations()
        }
    }
    private func refreshTranslations() {
        guard let chapter, let storage = model.store else { return }
        do {
            let rows = try ParagraphTranslationStore(library: storage, bookID: bookID).load(chapter: chapter.id)
            translatedText = TranslatedText(source: chapter.text, translations: rows, visible: records.translationsVisible ?? true)
        } catch { translatedText = TranslatedText(source: chapter.text); model.error = error.localizedDescription }
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
    private func changeRecords(_ change: (inout BookRecords) throws -> Void) {
        guard let book else { return }
        model.perform { records = try model.modifyRecords(for: book, change) }
    }
    @ViewBuilder private func bookmarkList(book: Book) -> some View {
        Section("已保存的书签") {
            if records.bookmarks.isEmpty { Text("还没有书签，保存当前位置后可以随时跳回来。").foregroundStyle(.secondary) }
            ForEach(records.bookmarks) { bookmark in
                Button {
                    if book.format == "txt" { loadChapter(bookmark.position.chapter, offset: bookmark.position.offset) }
                    else { NotificationCenter.default.post(name: .epubJump, object: EPUBJump(bookID: book.id, chapter: bookmark.position.chapter, offset: bookmark.position.offset, locator: bookmark.locator)) }
                    sheet = nil
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(bookmark.label)
                        if let date = bookmark.createdAt { Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                    }
                }.accessibilityIdentifier("bookmark-" + bookmark.id.uuidString)
            }.onDelete { offsets in
                let ids = Set(offsets.map { records.bookmarks[$0].id })
                changeRecords { $0.bookmarks.removeAll { ids.contains($0.id) } }
            }
        }
    }
    @discardableResult private func addBookmark() -> String {
        guard let book else { return "书籍已移除" }
        do {
            var added = false
            records = try model.modifyRecords(for: book) { value in
                if !value.bookmarks.contains(where: { $0.isAt(position: book.position, locator: book.epubLocator) }) {
                    value.bookmarks.append(Bookmark(position: book.position, label: chapter?.title ?? book.title, locator: book.epubLocator))
                    added = true
                }
            }
            bookmarkMessage = added ? "书签已保存" : "这里已经有书签了"
        } catch { model.error = error.localizedDescription; bookmarkMessage = "书签未能保存，请重试" }
        return bookmarkMessage ?? "书签未能保存，请重试"
    }
    private func performTapAction(_ action: ReaderTapAction) {
        guard sheet == nil, selection == nil, chat == nil, scenePhase == .active, let book else { return }
        autoRead.pause("点按阅读操作后已暂停")
        switch action {
        case .none, .previousPage, .nextPage: break
        case .menu: immersive.toggle()
        case .contents: sheet = .contents
        case .bookmarks: bookmarkMessage = nil; sheet = .bookmarks
        case .settings: sheet = .typography
        case .search: sheet = .search
        case .englishLearning: sheet = .englishLearning
        case .previousChapter, .nextChapter:
            let index = book.position.chapter + (action == .previousChapter ? -1 : 1)
            guard book.chapters.indices.contains(index) else { actionMessage = index < 0 ? "已经是第一章" : "已经是最后一章"; return }
            if book.format == "txt" { loadChapter(index) }
            else { NotificationCenter.default.post(name: .epubJump, object: EPUBJump(bookID: bookID, chapter: index, offset: 0)) }
        case .toggleTranslations:
            changeRecords { $0.translationsVisible = !($0.translationsVisible ?? true) }
            actionMessage = records.translationsVisible == false ? "译文已隐藏" : "译文已显示"
        case .toggleBookmark:
            do {
                var removed = false
                records = try model.modifyRecords(for: book) { value in
                    if value.bookmarks.contains(where: { $0.isAt(position: book.position, locator: book.epubLocator) }) {
                        value.bookmarks.removeAll { $0.isAt(position: book.position, locator: book.epubLocator) }; removed = true
                    } else { value.bookmarks.append(Bookmark(position: book.position, label: chapter?.title ?? book.title, locator: book.epubLocator)) }
                }
                actionMessage = removed ? "书签已移除" : "书签已保存"
            } catch { model.error = error.localizedDescription }
        }
    }
    private func saveAnnotation(_ passage: SourcePassage) {
        guard let book else { return }
        model.perform {
            records = try model.modifyRecords(for: book) { $0.annotations.append(Annotation(passage: passage, note: note, style: style)) }
            selection = nil
        }
    }
    private func recordTime() {
        guard let start = readingStarted else { return }
        readingStarted = nil
        let end = Date()
        changeRecords { $0.recordReading(from: start, to: end) }
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

struct TextReader {
    let autoRead: AutoReadSession
    let onAutoNext: () -> Bool
    let presentation: TranslatedText
    var text: String { presentation.text }
    var speechDisplayRanges: [NSRange] { speechRange.map { presentation.displayRanges(forSource: $0) } ?? [] }
    let font: UIFont
    let fontSize: Double
    let lineSpacing: Double
    let typography: ReaderTypography
    let paper: UIColor
    let backgroundImage: UIImage?
    let ink: UIColor
    let night: Bool
    let offset: Int
    let navigationID: UUID
    let annotations: [Annotation]
    let wordGlosses: [String: DictionaryGloss]
    let speechRange: NSRange?
    let immersive: Bool
    let tapZones: ReaderTapZones?
    let onTapAction: (ReaderTapAction) -> Void
    let onToggleControls: () -> Void
    let onBookmark: () -> String
    let isReading: Bool
    let onPosition: (Int, NSRange) -> Void
    let onSelection: (NSRange) -> Void
    let onTranslation: (NSRange) -> Void
    let onDictionary: (String, NSRange) -> Void
    var attributedText: NSAttributedString {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = lineSpacing; paragraph.paragraphSpacing = typography.paragraphSpacing
        paragraph.firstLineHeadIndent = typography.firstLineIndent * fontSize
        paragraph.alignment = typography.justified ? .justified : .natural
        let value = NSMutableAttributedString(string: text, attributes: [.font: font, .kern: typography.letterSpacing * fontSize, .foregroundColor: ink, .paragraphStyle: paragraph])
        let translatedParagraph = paragraph.mutableCopy() as! NSMutableParagraphStyle
        translatedParagraph.firstLineHeadIndent = 0
        for insertion in presentation.insertions {
            value.addAttributes([.font: font.withSize(font.pointSize * 0.9), .foregroundColor: ink.withAlphaComponent(0.78), .paragraphStyle: translatedParagraph], range: insertion.textRange)
        }
        for annotation in annotations {
            for range in presentation.displayRanges(forSource: NSRange(location: annotation.passage.offset, length: annotation.passage.text.utf16.count)) {
                if annotation.style == "highlight" { value.addAttribute(.backgroundColor, value: UIColor.systemYellow.withAlphaComponent(0.28), range: range) }
                else { value.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: UIColor.systemOrange], range: range) }
                if annotation.style == "wave" { value.addAttribute(AnnotationLayoutManager.waveKey, value: true, range: range) }
            }
        }
        applyEnglishReading(to: value)
        return value
    }
    func selectionActions(for range: NSRange) -> [UIAction] {
        guard range.location >= 0, range.length > 0, range.location <= text.utf16.count, range.length <= text.utf16.count - range.location,
              let original = presentation.sourceRange(forDisplay: range), original.length > 0 else { return [] }
        let action: UIAction
        if presentation.containsTranslation(in: range) {
            action = UIAction(title: "本段译文", image: UIImage(systemName: "character.book.closed")) { _ in onTranslation(original) }
        } else { action = UIAction(title: "批注", image: UIImage(systemName: "pencil")) { _ in onSelection(original) } }
        let word = (text as NSString).substring(with: range)
        return [action, UIAction(title: "查字词", image: UIImage(systemName: "character.book.closed")) { _ in onDictionary(word, original) }]
    }

}

final class AnnotationLayoutManager: NSLayoutManager {
    static let waveKey = NSAttributedString.Key("MoReadWaveUnderline")
    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        drawWordGlosses(for: glyphsToShow, at: origin)
    }
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
