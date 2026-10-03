import SwiftUI
import UIKit
import WebKit
import MoReadCore
import ReadiumShared
import ReadiumStreamer
import ReadiumNavigator

struct EPUBJump {
    let bookID: UUID
    let chapter: Int
    let offset: Int
    var locator: Data? = nil
}
extension Notification.Name {
    static let epubJump = Notification.Name("MoRead.EPUBJump")
    static let epubCapturePage = Notification.Name("MoRead.EPUBCapturePage")
}

@MainActor
final class EPUBService {
    static let shared = EPUBService()
    private let http = DefaultHTTPClient()
    private lazy var assets = AssetRetriever(httpClient: http)
    private lazy var opener = PublicationOpener(parser: DefaultPublicationParser(httpClient: http, assetRetriever: assets, pdfFactory: DefaultPDFDocumentFactory()))

    func open(_ url: URL, overrides: [String: String] = [:], conversion: ChineseConversionMode = .off) async throws -> Publication {
        guard let file = FileURL(url: url) else { throw MoReadError.invalid("书籍地址无效。") }
        let asset = try await assets.retrieve(url: file).get()
        let publication = try await opener.open(asset: asset, allowUserInteraction: false, onCreatePublication: { manifest, container, _ in
            let pages = Set((manifest.readingOrder + manifest.resources).filter { $0.mediaType == .xhtml || $0.mediaType == .html }.map { $0.url().string.components(separatedBy: "#")[0] })
            container = container.map { href, resource in
                let changed = overrides[href.string]
                guard conversion != .off, pages.contains(href.string) else {
                    return changed.map { html in resource.map { _ in Data(html.utf8) } } ?? resource
                }
                return DataResource {
                    defer { resource.close() }
                    do {
                        let data: Data
                        if let changed { data = Data(changed.utf8) }
                        else { data = try await resource.read(range: 0..<UInt64(16 * 1024 * 1024 + 1)).get() }
                        guard data.count <= 16 * 1024 * 1024, let html = String(data: data, encoding: .utf8) else { throw MoReadError.invalid("本页过大或文字编码无法识别。") }
                        let worker = Task.detached { Data(try EPUBChineseText.convert(html: html, mode: conversion).utf8) }
                        return .success(try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() })
                    } catch { return .failure(.decoding(error)) }
                }
            }
        }).get()
        guard !publication.isRestricted else { throw MoReadError.invalid("这本 EPUB 有加密保护，无法直接打开。") }
        guard !publication.readingOrder.isEmpty else { throw MoReadError.invalid("EPUB 的阅读顺序为空。") }
        return publication
    }

    func importBook(url: URL, store: LibraryStore) async throws -> Book {
        let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard fileSize < 500 * 1024 * 1024 else { throw MoReadError.invalid("EPUB 超过 500 MB，请先缩小书籍文件。") }
        let publication = try await open(url)
        let (chapters, anchors) = try await extract(publication)
        let cover = try await embeddedCover(in: publication)
        try Task.checkCancellation()
        return try store.importBook(title: publication.metadata.title ?? url.deletingPathExtension().lastPathComponent,
                                    author: publication.metadata.authors.map(\.name).joined(separator: "、"),
                                    chapters: chapters, original: url, format: "epub", readingMap: JSONEncoder().encode(anchors), cover: cover)
    }
    private func extract(_ publication: Publication) async throws -> ([MoReadCore.Chapter], [EPUBAnchor]) {
        let links = publication.readingOrder
        guard !links.isEmpty, links.count <= 50_000 else { throw MoReadError.invalid("EPUB 的阅读顺序无效。") }
        var chapters = links.enumerated().map { MoReadCore.Chapter(id: $0.offset, title: $0.element.title ?? "第 \($0.offset + 1) 章", text: "") }
        let paths = links.map { $0.url().string.components(separatedBy: "#")[0] }
        func applyTitles(_ contents: [ReadiumShared.Link]) {
            for link in contents {
                if let title = link.title, let index = paths.firstIndex(of: link.url().string.components(separatedBy: "#")[0]) { chapters[index].title = title }
                applyTitles(link.children)
            }
        }
        if case .success(let contents) = await publication.tableOfContents() { applyTitles(contents) }
        var anchors: [EPUBAnchor] = []
        var totalLength = 0
        if let iterator = publication.content()?.iterator() {
            while let element = try await iterator.next() {
                try Task.checkCancellation()
                guard let textual = element as? TextualContentElement, let text = textual.text, !text.isEmpty,
                      let index = paths.firstIndex(of: element.locator.href.string.components(separatedBy: "#")[0]) else { continue }
                totalLength += text.utf8.count
                guard totalLength <= 100 * 1024 * 1024, anchors.count < 1_000_000 else { throw MoReadError.invalid("EPUB 解压后的正文过大。") }
                if let locator = element.locator.jsonString { anchors.append(EPUBAnchor(chapter: index, offset: chapters[index].text.utf16.count, locator: locator)) }
                chapters[index].text += text + "\n"
            }
        }
        return (chapters, anchors)
    }
    func replaceSelectedText(_ passage: SourcePassage, with replacement: String, store: LibraryStore) async throws -> Book {
        let book = try store.book(passage.bookID), source = try store.chapter(passage.chapter, in: book)
        guard book.format == "epub", book.hasBody, !book.removed, passage.isValid(in: source, scope: .wholeBook) else { throw MoReadError.invalid("选中的原文已变化，请重新选择。") }
        let directory = store.directory(book.id), original = directory.appendingPathComponent("original.epub")
        let records = try Data(contentsOf: directory.appendingPathComponent("records.json")), oldOverrides = try store.epubOverrides(book.id)
        let anchors = try JSONDecoder().decode([EPUBAnchor].self, from: Data(contentsOf: directory.appendingPathComponent("epub-map.json")))
        let publication = try await open(original, overrides: oldOverrides)
        guard publication.readingOrder.indices.contains(passage.chapter), let resource = publication.get(publication.readingOrder[passage.chapter]) else { throw MoReadError.invalid("无法读取所选章节的排版内容。") }
        defer { resource.close() }
        let href = publication.readingOrder[passage.chapter].url().string.components(separatedBy: "#")[0]
        let data = try await resource.read(range: 0..<UInt64(16 * 1024 * 1024 + 1)).get()
        guard data.count <= 16 * 1024 * 1024, let html = String(data: data, encoding: .utf8) else { throw MoReadError.invalid("本页过大或文字编码无法识别。") }
        let worker = Task.detached {
            try EPUBTextEditing.replace(html: html, chapter: source, anchors: anchors, range: NSRange(location: passage.offset, length: passage.text.utf16.count), with: replacement)
        }
        let edited = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        var overrides = oldOverrides; overrides[href] = edited
        let updated = try await open(original, overrides: overrides)
        let (chapters, newAnchors) = try await extract(updated)
        try Task.checkCancellation()
        guard chapters.count == book.chapters.count, chapters.enumerated().allSatisfy({ $0.offset == passage.chapter || ChapterInfo($0.element) == book.chapters[$0.offset] }) else { throw MoReadError.invalid("修订影响了其他章节，原书籍已保留。") }
        let root = store.root, savedOverrides = overrides
        let commit = Task.detached {
            try LibraryStore(root: root).commitEPUBEdit(book: book, passage: passage, chapters: chapters, anchors: newAnchors, overrides: savedOverrides, originalRecords: records, originalOverrides: oldOverrides)
        }
        return try await withTaskCancellationHandler { try await commit.value } onCancel: { commit.cancel() }
    }
    private func embeddedCover(in publication: Publication) async throws -> Data? {
        var links = publication.linksWithRel(.cover)
        if let first = publication.readingOrder.first {
            if first.mediaType?.isBitmap == true { links.append(first) }
            links += first.alternates.filter { $0.mediaType?.isBitmap == true }
        }
        for link in links.prefix(32) {
            try Task.checkCancellation()
            guard !link.templated, URLComponents(string: link.url().string)?.scheme == nil, URLComponents(string: link.url().string)?.host == nil,
                  let resource = publication.get(link) else { continue }
            defer { resource.close() }
            if let count = try? await resource.estimatedLength().get(), count > 32 * 1024 * 1024 { continue }
            guard let data = try? await resource.read(range: 0..<UInt64(32 * 1024 * 1024 + 1)).get(),
                  let image = try? ReaderImage.thumbnail(data, maximum: 1800), let jpeg = try? ReaderImage.coverJPEG(image) else { continue }
            try Task.checkCancellation(); return jpeg
        }
        try Task.checkCancellation(); return nil
    }
}

struct EPUBReader: UIViewControllerRepresentable {
    let autoRead: AutoReadSession
    let isReading: Bool
    let onBookmark: () -> String
    let tapZones: ReaderTapZones?
    let onTapAction: (ReaderTapAction) -> Void
    let book: Book
    let initialPassage: SourcePassage?
    let initialPassageScope: ReadingScope?
    let fontSize: Double
    let lineSpacing: Double
    let typography: ReaderTypography
    let paper: String
    let annotations: [Annotation]
    let speechLocation: SpeechLocation?
    let onToggleControls: () -> Void
    let onLocation: (Data) -> Void
    let onSelection: (SourcePassage, Bool) -> Void
    let onVisiblePage: (SourcePassage?) -> Void
    let onDictionary: (String, SourcePassage?) -> Void
    let onEdit: (SourcePassage) -> Void
    @EnvironmentObject private var model: LibraryModel

    func makeUIViewController(context: Context) -> EPUBHostController {
        EPUBHostController(autoRead: autoRead, isReading: isReading, onBookmark: onBookmark, tapZones: tapZones, onTapAction: onTapAction, book: book, initialPassage: initialPassage, initialPassageScope: initialPassageScope, model: model, fontSize: fontSize, lineSpacing: lineSpacing, typography: typography, paper: paper, annotations: annotations, onToggleControls: onToggleControls, onLocation: onLocation, onSelection: onSelection, onVisiblePage: onVisiblePage, onDictionary: onDictionary, onEdit: onEdit)
    }
    func updateUIViewController(_ controller: EPUBHostController, context: Context) {
        controller.tapZones = tapZones
        controller.isReading = isReading
        controller.setPreferences(fontSize: fontSize, lineSpacing: lineSpacing, typography: typography, paper: paper)
        controller.setAnnotations(annotations)
        controller.setSpeechLocation(speechLocation)
        controller.setRecordsRevision(model.recordsRevision)
        controller.setVocabularyRevision(model.vocabularyRevision)
    }
    static func dismantleUIViewController(_ controller: EPUBHostController, coordinator: ()) { controller.close() }
}

@MainActor
final class EPUBHostController: ReaderKeyboardController, EPUBNavigatorDelegate {
    private let autoRead: AutoReadSession
    private let autoReadOwner = UUID()
    var isReading: Bool { didSet { if !isReading { bookmarkPull?.cancel() }; updateKeyboard() } }
    private let onBookmark: () -> String
    var tapZones: ReaderTapZones?
    private let onTapAction: (ReaderTapAction) -> Void
    private var bookmarkPull: BookmarkPull?
    private var closed = false
    private let bookID: UUID
    private let initialPassage: SourcePassage?
    private let initialPassageScope: ReadingScope?
    private let model: LibraryModel
    private let onToggleControls: () -> Void
    private let onLocation: (Data) -> Void
    private let onSelection: (SourcePassage, Bool) -> Void
    private let onVisiblePage: (SourcePassage?) -> Void
    private let onDictionary: (String, SourcePassage?) -> Void
    private let onEdit: (SourcePassage) -> Void
    private var navigator: EPUBNavigatorViewController?
    private var anchors: [EPUBAnchor] = []
    private var openTask: Task<Void, Never>?
    private var locationTask: Task<Bool, Never>?
    private var selectionTask: Task<Void, Never>?
    private var fontSize: Double
    private var lineSpacing: Double
    private var typography: ReaderTypography
    private var paper: String
    private var annotations: [Annotation]
    private var speechLocation: SpeechLocation?
    private var speechAnchor: String?
    private var recordsRevision: UUID?
    private var vocabularyRevision: UUID?
    private var wordGlosses: [String: DictionaryGloss] = [:]
    private var pendingTranslationLocator: Locator?
    private var translationCache: (chapter: Int, source: String, records: UUID?, rows: [ParagraphTranslation])?

    init(autoRead: AutoReadSession, isReading: Bool, onBookmark: @escaping () -> String, tapZones: ReaderTapZones?, onTapAction: @escaping (ReaderTapAction) -> Void, book: Book, initialPassage: SourcePassage?, initialPassageScope: ReadingScope?, model: LibraryModel, fontSize: Double, lineSpacing: Double, typography: ReaderTypography, paper: String, annotations: [Annotation], onToggleControls: @escaping () -> Void, onLocation: @escaping (Data) -> Void, onSelection: @escaping (SourcePassage, Bool) -> Void, onVisiblePage: @escaping (SourcePassage?) -> Void, onDictionary: @escaping (String, SourcePassage?) -> Void, onEdit: @escaping (SourcePassage) -> Void) {
        self.tapZones = tapZones; self.onTapAction = onTapAction
        self.autoRead = autoRead; self.isReading = isReading; self.onBookmark = onBookmark
        bookID = book.id; self.model = model; self.fontSize = fontSize; self.lineSpacing = lineSpacing; self.typography = typography; self.paper = paper; self.annotations = annotations
        self.initialPassage = initialPassage; self.initialPassageScope = initialPassageScope
        self.onToggleControls = onToggleControls; self.onLocation = onLocation; self.onSelection = onSelection; self.onVisiblePage = onVisiblePage; self.onDictionary = onDictionary; self.onEdit = onEdit
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var keyboardReady: Bool { !closed && isReading }
    override func turnWithKey(_ forward: Bool) {
        guard !closed, isReading, let navigator, navigator.currentSelection == nil else { return }
        var surface = navigator.view.hitTest(CGPoint(x: navigator.view.bounds.midX, y: navigator.view.bounds.midY), with: nil)
        while let node = surface, !(node is WKWebView) { surface = node.superview }
        Task { await turnPage(forward, surface: surface) }
    }
    private func turnPage(_ forward: Bool, surface: UIView?) async {
        guard !closed, isReading, let reader = navigator, reader.currentSelection == nil else { return }
        if reader.settings.scroll, let web = surface as? WKWebView {
            let result = await reader.evaluateJavaScript("getComputedStyle(document.documentElement).writingMode.startsWith('vertical')")
            guard let horizontal = (try? result.get()) as? Bool, !closed, isReading else { return }
            let scroll = web.scrollView, inset = scroll.adjustedContentInset
            let position = horizontal ? scroll.contentOffset.x : scroll.contentOffset.y
            let length = horizontal ? scroll.bounds.width : scroll.bounds.height
            let lower = horizontal ? -inset.left : -inset.top
            let upper = max(lower, (horizontal ? scroll.contentSize.width + inset.right : scroll.contentSize.height + inset.bottom) - length)
            let step = length * 0.9 * (!forward ? -1 : 1) * (horizontal ? -1 : 1)
            let target = min(upper, max(lower, position + step))
            if abs(target - position) > 0.5 {
                var offset = scroll.contentOffset
                if horizontal { offset.x = target } else { offset.y = target }
                scroll.setContentOffset(offset, animated: !UIAccessibility.isReduceMotionEnabled); return
            }
        }
        if !forward { _ = await reader.goBackward(options: NavigatorGoOptions(animated: !UIAccessibility.isReduceMotionEnabled)) }
        else { _ = await reader.goForward(options: NavigatorGoOptions(animated: !UIAccessibility.isReduceMotionEnabled)) }
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        keyboardSession = autoRead
        view.addGestureRecognizer(AutoReadTouch(autoRead))
        autoRead.attach(autoReadOwner) { [weak self] amount in
            guard let self else { return .waiting }
            return await advanceAutomatically(amount)
        }
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(spinner)
        NSLayoutConstraint.activate([spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor), spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
        spinner.startAnimating()
        NotificationCenter.default.addObserver(self, selector: #selector(jump(_:)), name: .epubJump, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(capturePage(_:)), name: .epubCapturePage, object: nil)
        openTask = Task { [weak self] in
            guard let self, let book = model.books.first(where: { $0.id == self.bookID }), let store = model.store else { return }
            do {
                let directory = store.directory(bookID)
                let publication = try await EPUBService.shared.open(directory.appendingPathComponent("original.epub"), overrides: store.epubOverrides(bookID), conversion: book.chineseConversion ?? .off)
                try Task.checkCancellation()
                anchors = try JSONDecoder().decode([EPUBAnchor].self, from: Data(contentsOf: directory.appendingPathComponent("epub-map.json")))
                let locator: Locator?
                if let passage = initialPassage {
                    guard let current = model.books.first(where: { $0.id == bookID }), !current.removed,
                          passage.bookID == bookID, passage.isValid(in: try store.chapter(passage.chapter, in: current), scope: initialPassageScope ?? ReadingScope(through: current.readThrough)),
                          let exact = self.locator(for: passage, publication: publication) else { throw MoReadError.invalid("原文或已读范围已经变化，请重新打开。") }
                    locator = exact
                } else {
                    let saved = try book.epubLocator.flatMap { try Locator(json: JSONSerialization.jsonObject(with: $0)) }
                    let link = publication.readingOrder[min(book.position.chapter, publication.readingOrder.count - 1)]
                    locator = saved ?? Locator(href: link.url(), mediaType: link.mediaType ?? .xhtml, locations: .init(progression: 0))
                }
                pendingTranslationLocator = locator
                var templates = HTMLDecorationTemplate.defaultTemplates()
                templates["wave"] = HTMLDecorationTemplate(layout: .boxes, element: "<div class='moread-wave'/>", stylesheet: """
                .moread-wave { background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='8' height='4'%3E%3Cpath d='M0 2 Q2 0 4 2 T8 2' fill='none' stroke='%23d67b16' stroke-width='1.3'/%3E%3C/svg%3E"); background-repeat: repeat-x; background-position: bottom; }
                """)
                var config = EPUBNavigatorViewController.Configuration(preferences: preferences,
                    editingActions: EditingAction.defaultActions + [EditingAction(title: "批注", action: #selector(annotate)), EditingAction(title: "编辑原文", action: #selector(editSelection)), EditingAction(title: "查字词", action: #selector(lookupSelection))], decorationTemplates: templates)
                if let url = Bundle.main.url(forResource: "NotoSerifSC", withExtension: "ttf"), let file = FileURL(url: url) {
                    config.fontFamilyDeclarations.append(CSSFontFamilyDeclaration(fontFamily: "Noto Serif SC", alternates: [.serif], fontFaces: [CSSFontFace(file: file, weight: .variable(200...900))]).eraseToAnyHTMLFontFamilyDeclaration())
                }
                if let library = model.fontLibrary {
                    for font in model.fonts {
                        if let file = FileURL(url: library.file(font)) {
                            config.fontFamilyDeclarations.append(CSSFontFamilyDeclaration(fontFamily: FontFamily(rawValue: "MoRead-" + font.id.uuidString), fontFaces: [CSSFontFace(file: file)]).eraseToAnyHTMLFontFamilyDeclaration())
                        }
                    }
                }
                let reader = try EPUBNavigatorViewController(publication: publication, initialLocation: locator, config: config)
                navigator = reader; reader.delegate = self
                addChild(reader); reader.view.frame = view.bounds
                reader.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                view.addSubview(reader.view); reader.didMove(toParent: self)
                renderAnnotations()
                bookmarkPull = BookmarkPull(in: reader.view, canStart: { [weak self] in
                    guard let self, let navigator else { return false }
                    return !closed && isReading && navigator.currentLocation != nil && !navigator.settings.scroll && navigator.currentSelection == nil && !model.maintenance
                }, save: { [weak self] in
                    guard let self else { return "阅读页已关闭" }
                    let capture = refreshVisiblePage(recordPosition: true)
                    guard await capture.value, !closed, isReading, !Task.isCancelled else { return "阅读位置已改变，请重试" }
                    return onBookmark()
                })
                spinner.removeFromSuperview()
            } catch is CancellationError {} catch { model.error = error.localizedDescription; spinner.stopAnimating() }
        }
    }
    func navigator(_ navigator: EPUBNavigatorViewController, setupUserScripts controller: WKUserContentController) {
        if model.books.first(where: { $0.id == bookID })?.chineseConversion != nil,
           let url = Bundle.main.url(forResource: "EPUBChineseReading", withExtension: "js"), let script = try? String(contentsOf: url, encoding: .utf8) {
            controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        }
        if let url = Bundle.main.url(forResource: "EPUBEnglishReading", withExtension: "js"), let script = try? String(contentsOf: url, encoding: .utf8) {
            controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        }
        guard paper == "image", let data = model.readingBackgroundData else { return }
        let rgb = typography.backgroundRGB ?? 0xF7F2E3
        let shade = "rgba(\((rgb >> 16) & 255),\((rgb >> 8) & 255),\(rgb & 255),\(1 - (typography.backgroundOpacity ?? 0.25)))"
        let css = "html { isolation: isolate; } html::before { content: ''; position: fixed; inset: 0; z-index: -1; pointer-events: none; background: linear-gradient(\(shade), \(shade)), url(data:image/jpeg;base64,\(data.base64EncodedString())) center / cover no-repeat !important; } body { background: transparent !important; }"
        guard let encoded = try? JSONEncoder().encode(css), let quoted = String(data: encoded, encoding: .utf8) else { return }
        let script = "const style = document.createElement('style'); style.textContent = \(quoted); document.head.appendChild(style);"
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    }
    private var preferences: EPUBPreferences {
        let custom = !typography.publisherStyles
        let imported = model.fonts.first { $0.id == typography.customFontID }
        let family: FontFamily? = imported.map { FontFamily(rawValue: "MoRead-" + $0.id.uuidString) } ?? (typography.font == .system ? nil : typography.font == .serif ? FontFamily(rawValue: "Noto Serif SC") : typography.font == .monospace ? .monospace : .sansSerif)
        return EPUBPreferences(backgroundColor: (paper == "custom" || paper == "image") ? ReadiumNavigator.Color(rawValue: typography.backgroundRGB ?? 0xF7F2E3) : nil, fontFamily: custom ? family : nil, fontSize: fontSize / 16,
                               fontWeight: custom && imported == nil ? Double(typography.weight) / 400 : nil,
                               letterSpacing: custom ? typography.letterSpacing * 2 : nil,
                               lineHeight: 1 + lineSpacing / fontSize, pageMargins: typography.epubPageMargins,
                               paragraphIndent: custom ? typography.firstLineIndent : nil,
                               paragraphSpacing: custom ? typography.paragraphSpacing / fontSize : nil,
                               publisherStyles: typography.publisherStyles, scroll: typography.epubScroll ?? false,
                               textAlign: custom ? (typography.justified ? .justify : .start) : nil,
                               textColor: (paper == "custom" || paper == "image") ? ReadiumNavigator.Color(rawValue: typography.textRGB ?? 0x292929) : nil,
                               theme: paper == "night" ? .dark : paper == "white" ? .light : .sepia)
    }
    func setPreferences(fontSize: Double, lineSpacing: Double, typography: ReaderTypography, paper: String) {
        guard fontSize != self.fontSize || lineSpacing != self.lineSpacing || paper != self.paper || typography != self.typography else { return }
        bookmarkPull?.cancel()
        self.fontSize = fontSize; self.lineSpacing = lineSpacing; self.typography = typography; self.paper = paper; navigator?.submitPreferences(preferences)
        refreshVisiblePage(recordPosition: false)
    }
    func setAnnotations(_ value: [Annotation]) {
        guard value != annotations else { return }
        annotations = value; renderAnnotations()
    }
    func setRecordsRevision(_ value: UUID) {
        guard value != recordsRevision else { return }
        recordsRevision = value
        refreshVisiblePage(recordPosition: false)
    }
    func setVocabularyRevision(_ value: UUID) {
        guard value != vocabularyRevision else { return }
        vocabularyRevision = value
        model.perform { wordGlosses = EnglishReading.unlearned(try model.vocabulary?.words() ?? []) }
        refreshVisiblePage(recordPosition: false)
    }
    private func renderAnnotations() {
        let decorations = annotations.compactMap { annotation -> Decoration? in
            guard let locator = locator(for: annotation.passage) else { return nil }
            let style: Decoration.Style = annotation.style == "wave" ? .init(id: "wave") : annotation.style == "underline" ? .underline(tint: .systemOrange) : .highlight(tint: .systemYellow)
            return Decoration(id: annotation.id.uuidString, locator: locator, style: style)
        }
        navigator?.apply(decorations: decorations, in: "annotations")
    }
    private func locator(for passage: SourcePassage, publication: Publication? = nil) -> Locator? {
        guard let book = model.books.first(where: { $0.id == bookID }), passage.bookID == bookID,
              let chapter = try? model.store?.chapter(passage.chapter, in: book), passage.isValid(in: chapter, scope: .wholeBook),
              let publication = publication ?? navigator?.publication, publication.readingOrder.indices.contains(passage.chapter) else { return nil }
        let href = publication.readingOrder[passage.chapter].url()
        if let data = passage.epubLocator, let exact = try? Locator(json: JSONSerialization.jsonObject(with: data)),
           exact.href.string.components(separatedBy: "#")[0] == href.string.components(separatedBy: "#")[0] { return exact }
        let end = passage.offset + passage.text.utf16.count
        let start = TextBoundary.floor(max(0, passage.offset - 80), in: chapter.text)
        let after = TextBoundary.floor(min(chapter.text.utf16.count, end + 80), in: chapter.text)
        let source = chapter.text as NSString
        return Locator(href: href, mediaType: .xhtml,
                       text: .init(after: source.substring(with: NSRange(location: end, length: after - end)), before: source.substring(with: NSRange(location: start, length: passage.offset - start)), highlight: passage.text))
    }
    func setSpeechLocation(_ value: SpeechLocation?) {
        let value = value?.bookID == bookID ? value : nil
        guard value != speechLocation else { return }
        speechLocation = value
        guard let value, let book = model.books.first(where: { $0.id == bookID }), let chapter = try? model.store?.chapter(value.chapter, in: book),
              value.range.location >= 0, NSMaxRange(value.range) <= chapter.text.utf16.count else {
            speechAnchor = nil; navigator?.apply(decorations: [], in: "speech"); return
        }
        let passage = SourcePassage(bookID: bookID, chapter: chapter, offset: value.range.location, text: (chapter.text as NSString).substring(with: value.range))
        if let locator = locator(for: passage) { navigator?.apply(decorations: [Decoration(id: "spoken", locator: locator, style: .highlight(tint: .systemTeal))], in: "speech") }
        if let anchor = anchors.last(where: { $0.chapter == value.chapter && $0.offset <= value.range.location }), anchor.locator != speechAnchor {
            speechAnchor = anchor.locator
            Task { if let locator = try? Locator(jsonString: anchor.locator) { pendingTranslationLocator = locator; _ = await navigator?.go(to: locator) } }
        }
    }
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        autoRead.pause("排版改变，已暂停")
        super.viewWillTransition(to: size, with: coordinator)
    }
    func close() {
        closed = true; bookmarkPull?.cancel(); autoRead.detach(autoReadOwner)
        openTask?.cancel(); locationTask?.cancel(); selectionTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }
    private func advanceAutomatically(_ amount: Double) async -> AutoReadSession.Result {
        guard !closed, !Task.isCancelled, let navigator, let location = navigator.currentLocation else { return .waiting }
        let scrolling = navigator.settings.scroll
        guard autoRead.settings.mode != .scroll || scrolling else { return .waiting }
        // Readium reloads resources asynchronously when the scroll preference changes.
        let probe = await navigator.evaluateJavaScript("document.readyState === 'complete' && !!document.scrollingElement && window.innerHeight > 0 && (document.documentElement.style.getPropertyValue('--USER__view').trim() === 'readium-scroll-on') === \(scrolling)")
        guard !closed, !Task.isCancelled, (try? probe.get()) as? Bool == true else { return .waiting }
        guard amount > 0 else { return .ready }
        if autoRead.settings.mode == .scroll {
            let script = """
            (() => {
                const e = document.scrollingElement;
                const vertical = getComputedStyle(document.documentElement).writingMode.startsWith('vertical');
                const limit = Math.max(0, vertical ? e.scrollWidth - innerWidth : e.scrollHeight - innerHeight);
                const position = vertical ? Math.abs(e.scrollLeft) : e.scrollTop;
                if (position >= limit - 0.5) return false;
                if (vertical) e.scrollLeft = -Math.min(limit, position + \(amount));
                else e.scrollTop = Math.min(limit, position + \(amount));
                return true;
            })()
            """
            let result = await navigator.evaluateJavaScript(script)
            guard !closed, !Task.isCancelled else { return .waiting }
            guard let moved = (try? result.get()) as? Bool else { return .waiting }
            if moved { return .ready }
            let links = navigator.publication.readingOrder
            guard let index = links.firstIndex(where: { $0.url().string.components(separatedBy: "#")[0] == location.href.string.components(separatedBy: "#")[0] }) else { return .waiting }
            guard index + 1 < links.count else { return .end }
            return await navigator.go(to: links[index + 1], options: .init()) ? .moved : .waiting
        }
        if await navigator.goForward(options: .init()) { return .moved }
        guard !Task.isCancelled else { return .waiting }
        return navigator.publication.readingOrder.last?.url().string.components(separatedBy: "#")[0] == location.href.string.components(separatedBy: "#")[0] ? .end : .waiting
    }
    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        refreshVisiblePage(recordPosition: true)
    }
    @objc private func capturePage(_ notification: Notification) {
        guard notification.object as? UUID == bookID else { return }
        refreshVisiblePage(recordPosition: false)
    }
    @discardableResult private func refreshVisiblePage(recordPosition: Bool) -> Task<Bool, Never> {
        locationTask?.cancel()
        let task = Task { [weak self] in
            guard let self, !Task.isCancelled, !closed else { return false }
            onVisiblePage(nil)
            do {
                let passage = try await sourcePassage(selecting: false)?.passage
                try Task.checkCancellation(); onVisiblePage(passage)
                if let data = passage?.epubLocator { onLocation(data) }
                else if recordPosition, let locator = navigator?.currentLocation { onLocation(try JSONSerialization.data(withJSONObject: locator.json)) }
                else { return false }
                if recordPosition, passage == nil, let exact = await navigator?.firstVisibleElementLocator(), !Task.isCancelled,
                   var book = model.books.first(where: { $0.id == bookID }), let position = position(for: exact, book: book) {
                    book.record(position: position, visibleEnd: position); model.update(book)
                }
                if recordPosition, let passage, var book = model.books.first(where: { $0.id == bookID }) {
                    // Only the first visible paragraph's start advances the EPUB watermark.
                    let position = ReadingPosition(chapter: passage.chapter, offset: passage.offset)
                    book.record(position: position, visibleEnd: position); model.update(book)
                }
                try Task.checkCancellation()
                return !closed && !model.maintenance
            } catch is CancellationError { return false } catch { onVisiblePage(nil); return false }
        }
        locationTask = task
        return task
    }
    private func sourcePassage(selecting: Bool) async throws -> (passage: SourcePassage, translation: Bool, selectedText: String?)? {
        guard !model.maintenance, let reader = navigator, let href = reader.currentLocation?.href,
              let book = model.books.first(where: { $0.id == bookID && !$0.removed && $0.hasBody }), let store = model.store,
              let index = reader.publication.readingOrder.firstIndex(where: { $0.url().string.components(separatedBy: "#")[0] == href.string.components(separatedBy: "#")[0] }) else { return nil }
        let chapter = try store.chapter(index, in: book)
        let blocks = try EPUBSourceBlock.blocks(in: chapter, anchors: anchors)
        let translations: [ParagraphTranslation]?
        if selecting { translations = nil }
        else if let cached = translationCache, cached.chapter == index, cached.source == chapter.revision, cached.records == recordsRevision {
            translations = cached.rows
        } else {
            let visible = try store.records(for: book).translationsVisible ?? true
            let rows = visible ? try ParagraphTranslationStore(library: store, bookID: bookID).load(chapter: index).filter { !$0.hidden } : []
            translationCache = (index, chapter.revision, recordsRevision, rows); translations = rows
        }
        let restoring = !selecting && pendingTranslationLocator?.href.string.components(separatedBy: "#")[0] == href.string.components(separatedBy: "#")[0] ? pendingTranslationLocator : nil
        let result = try await reader.evaluateJavaScript(EPUBSourceBlock.script(blocks: blocks, selecting: selecting, translations: translations, restoring: restoring, typography: selecting ? nil : typography, vocabulary: wordGlosses, conversion: book.chineseConversion ?? .off)).get()
        if restoring == pendingTranslationLocator, result is [String: Any] { pendingTranslationLocator = nil }
        try Task.checkCancellation()
        guard model.store === store, !model.maintenance, reader.currentLocation?.href == href,
              let value = result as? [String: Any], let start = value["start"] as? Int, let end = value["end"] as? Int,
              start >= 0, end > start, end <= chapter.text.utf16.count,
              TextBoundary.floor(start, in: chapter.text) == start, TextBoundary.floor(end, in: chapter.text) == end,
              try store.chapter(index, in: book).revision == chapter.revision else { return nil }
        if value["changed"] as? Bool == true { autoRead.pause("正文排版改变，已暂停") }
        var passage = SourcePassage(bookID: bookID, chapter: chapter, offset: start, text: (chapter.text as NSString).substring(with: NSRange(location: start, length: end - start)))
        if let selector = value["selector"] as? String {
            let text = try Locator.Text(json: value["text"])
            let locator = Locator(href: href, mediaType: .xhtml, locations: .init(otherLocations: ["cssSelector": selector]), text: text)
            passage.epubLocator = try JSONSerialization.data(withJSONObject: locator.json)
        }
        if selecting, value["translation"] as? Bool != true {
            let text = (value["text"] as? [String: Any])?["highlight"] as? String
            guard passage.text.filter({ !$0.isWhitespace }) == text?.filter({ !$0.isWhitespace }) else { return nil }
        }
        return (passage, value["translation"] as? Bool ?? false, value["selectedText"] as? String)
    }
    private func position(for locator: Locator, book: Book) -> ReadingPosition? {
        guard let reader = navigator,
              let chapterIndex = reader.publication.readingOrder.firstIndex(where: { $0.url().string.components(separatedBy: "#")[0] == locator.href.string.components(separatedBy: "#")[0] }),
              let text = locator.text.highlight, !text.isEmpty,
              let chapter = try? model.store?.chapter(chapterIndex, in: book) else { return nil }
        let source = chapter.text as NSString
        let found = source.range(of: text)
        guard found.location != NSNotFound else { return nil }
        let rest = NSRange(location: NSMaxRange(found), length: source.length - NSMaxRange(found))
        guard source.range(of: text, range: rest).location == NSNotFound else { return nil }
        return ReadingPosition(chapter: chapterIndex, offset: found.location)
    }
    @objc private func lookupSelection() {
        guard isReading, let text = navigator?.currentSelection?.locator.text.highlight, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        selectionTask?.cancel()
        selectionTask = Task {
            do {
                let result = try await sourcePassage(selecting: true)
                try Task.checkCancellation()
                guard isReading else { return }
                let matches = result.map { $0.translation || $0.selectedText?.filter { !$0.isWhitespace } == text.filter { !$0.isWhitespace } } ?? false
                onDictionary(text, matches ? result?.passage : nil); navigator?.clearSelection()
            } catch is CancellationError { }
            catch { if !Task.isCancelled, isReading { onDictionary(text, nil); navigator?.clearSelection() } }
        }
    }
    @objc private func editSelection() {
        guard isReading, let selected = navigator?.currentSelection else { return }
        selectionTask?.cancel()
        selectionTask = Task {
            do {
                guard let result = try await sourcePassage(selecting: true), !result.translation,
                      result.selectedText?.filter({ !$0.isWhitespace }) == selected.locator.text.highlight?.filter({ !$0.isWhitespace }) else { throw MoReadError.invalid("请选择可准确定位的原文，译文可在段落翻译中编辑。") }
                try Task.checkCancellation(); guard isReading else { return }
                onEdit(result.passage); navigator?.clearSelection()
            } catch is CancellationError {} catch { model.error = error.localizedDescription }
        }
    }
    @objc private func annotate() {
        guard let selected = navigator?.currentSelection else { return }
        selectionTask?.cancel()
        selectionTask = Task {
            do {
                guard let result = try await sourcePassage(selecting: true), result.passage.epubLocator != nil,
                      result.translation || result.selectedText?.filter({ !$0.isWhitespace }) == selected.locator.text.highlight?.filter({ !$0.isWhitespace }) else { throw MoReadError.invalid("暂时无法准确定位这段原文，请选择更完整的一段再试。") }
                onSelection(result.passage, result.translation); navigator?.clearSelection()
            } catch is CancellationError {} catch { model.error = error.localizedDescription }
        }
    }
    @objc private func jump(_ notification: Notification) {
        guard let jump = notification.object as? EPUBJump, jump.bookID == bookID else { return }
        autoRead.pause("阅读位置改变，已暂停")
        Task {
            do {
                let locator: Locator?
                if let data = jump.locator { locator = try Locator(json: JSONSerialization.jsonObject(with: data)) }
                else if let anchor = anchors.last(where: { $0.chapter == jump.chapter && $0.offset <= jump.offset }) {
                    locator = try Locator(jsonString: anchor.locator)
                } else if let reader = navigator, reader.publication.readingOrder.indices.contains(jump.chapter) {
                    _ = await reader.go(to: reader.publication.readingOrder[jump.chapter]); return
                } else { locator = nil }
                if let locator { pendingTranslationLocator = locator; _ = await navigator?.go(to: locator) }
            } catch { model.error = error.localizedDescription }
        }
    }
    func navigator(_ navigator: VisualNavigator, didTapAt point: CGPoint) {
        guard isReading, !closed else { return }
        Task {
            guard let reader = self.navigator, let href = reader.currentLocation?.href else { return }
            let result = await reader.evaluateJavaScript("(() => { const s = window.__moreadEnglish, tap = s?.lastTap; if (s) s.lastTap = null; return tap && Date.now() - tap.time < 2000 ? tap : null; })()")
            guard !closed, isReading, reader.currentLocation?.href == href else { return }
            if let hit = (try? result.get()) as? [String: Any], let word = hit["word"] as? String,
               let start = hit["start"] as? Int, let end = hit["end"] as? Int,
               let index = reader.publication.readingOrder.firstIndex(where: { $0.url().string.components(separatedBy: "#")[0] == href.string.components(separatedBy: "#")[0] }),
               let book = model.books.first(where: { $0.id == bookID }), let chapter = try? model.store?.chapter(index, in: book),
               start >= 0, end > start, end <= chapter.text.utf16.count {
                let text = (chapter.text as NSString).substring(with: NSRange(location: start, length: end - start))
                if VocabularyWord.normalize(text) == word {
                    let passage = SourcePassage(bookID: bookID, chapter: chapter, offset: start, text: text)
                    onDictionary(text, passage); return
                }
            }
            guard reader.currentSelection == nil else { return }
            if let tapZones {
                var hit = reader.view.hitTest(point, with: nil)
                while let node = hit, !(node is WKWebView) { hit = node.superview }
                let surface = hit ?? reader.view!
                let local = surface.convert(point, from: reader.view)
                let action = tapZones.action(x: local.x - surface.bounds.minX, y: local.y - surface.bounds.minY, width: surface.bounds.width, height: surface.bounds.height)
                switch action {
                case .previousPage, .nextPage:
                    await turnPage(action == .nextPage, surface: surface)
                case .toggleBookmark:
                    guard await refreshVisiblePage(recordPosition: true).value, !closed, isReading else { return }
                    onTapAction(action)
                default: onTapAction(action)
                }
            } else if abs(point.x - view.bounds.midX) < view.bounds.width / 6 { onToggleControls() }
        }
    }
    func navigator(_ navigator: Navigator, presentError error: NavigatorError) { autoRead.pause("正文暂不可用，已暂停"); model.error = "阅读操作失败，请重新打开这本书。" }
    func navigator(_ navigator: Navigator, didFailToLoadResourceAt href: RelativeURL, withError error: ReadError) { autoRead.pause("正文暂不可用，已暂停"); model.error = "书内资源无法读取，请检查 EPUB 文件是否完整。" }
}
