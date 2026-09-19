import SwiftUI
import UIKit
import WebKit
import MoReadCore
import ReadiumShared
import ReadiumStreamer
import ReadiumNavigator

struct EPUBAnchor: Codable {
    let chapter: Int
    let offset: Int
    let locator: String
}

struct EPUBJump {
    let bookID: UUID
    let chapter: Int
    let offset: Int
    var locator: Data? = nil
}
extension Notification.Name { static let epubJump = Notification.Name("MoRead.EPUBJump") }

@MainActor
final class EPUBService {
    static let shared = EPUBService()
    private let http = DefaultHTTPClient()
    private lazy var assets = AssetRetriever(httpClient: http)
    private lazy var opener = PublicationOpener(parser: DefaultPublicationParser(httpClient: http, assetRetriever: assets, pdfFactory: DefaultPDFDocumentFactory()))

    func open(_ url: URL) async throws -> Publication {
        guard let file = FileURL(url: url) else { throw MoReadError.invalid("书籍地址无效。") }
        let asset = try await assets.retrieve(url: file).get()
        let publication = try await opener.open(asset: asset, allowUserInteraction: false).get()
        guard !publication.isRestricted else { throw MoReadError.invalid("这本 EPUB 有加密保护，无法直接打开。") }
        return publication
    }

    func importBook(url: URL, store: LibraryStore) async throws -> Book {
        let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard fileSize < 500 * 1024 * 1024 else { throw MoReadError.invalid("EPUB 超过 500 MB，请先缩小书籍文件。") }
        let publication = try await open(url)
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
        return try store.importBook(title: publication.metadata.title ?? url.deletingPathExtension().lastPathComponent,
                                    author: publication.metadata.authors.map(\.name).joined(separator: "、"),
                                    chapters: chapters, original: url, format: "epub", readingMap: JSONEncoder().encode(anchors))
    }
}

struct EPUBReader: UIViewControllerRepresentable {
    let book: Book
    let fontSize: Double
    let lineSpacing: Double
    let typography: ReaderTypography
    let paper: String
    let annotations: [Annotation]
    let speechLocation: SpeechLocation?
    let onToggleControls: () -> Void
    let onLocation: (Data) -> Void
    let onSelection: (SourcePassage) -> Void
    @EnvironmentObject private var model: LibraryModel

    func makeUIViewController(context: Context) -> EPUBHostController {
        EPUBHostController(book: book, model: model, fontSize: fontSize, lineSpacing: lineSpacing, typography: typography, paper: paper, annotations: annotations, onToggleControls: onToggleControls, onLocation: onLocation, onSelection: onSelection)
    }
    func updateUIViewController(_ controller: EPUBHostController, context: Context) {
        controller.setPreferences(fontSize: fontSize, lineSpacing: lineSpacing, typography: typography, paper: paper)
        controller.setAnnotations(annotations)
        controller.setSpeechLocation(speechLocation)
    }
    static func dismantleUIViewController(_ controller: EPUBHostController, coordinator: ()) { controller.close() }
}

@MainActor
final class EPUBHostController: UIViewController, EPUBNavigatorDelegate {
    private let bookID: UUID
    private let model: LibraryModel
    private let onToggleControls: () -> Void
    private let onLocation: (Data) -> Void
    private let onSelection: (SourcePassage) -> Void
    private var navigator: EPUBNavigatorViewController?
    private var anchors: [EPUBAnchor] = []
    private var openTask: Task<Void, Never>?
    private var locationTask: Task<Void, Never>?
    private var fontSize: Double
    private var lineSpacing: Double
    private var typography: ReaderTypography
    private var paper: String
    private var annotations: [Annotation]
    private var speechLocation: SpeechLocation?
    private var speechAnchor: String?

    init(book: Book, model: LibraryModel, fontSize: Double, lineSpacing: Double, typography: ReaderTypography, paper: String, annotations: [Annotation], onToggleControls: @escaping () -> Void, onLocation: @escaping (Data) -> Void, onSelection: @escaping (SourcePassage) -> Void) {
        bookID = book.id; self.model = model; self.fontSize = fontSize; self.lineSpacing = lineSpacing; self.typography = typography; self.paper = paper; self.annotations = annotations
        self.onToggleControls = onToggleControls; self.onLocation = onLocation; self.onSelection = onSelection
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(spinner)
        NSLayoutConstraint.activate([spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor), spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
        spinner.startAnimating()
        NotificationCenter.default.addObserver(self, selector: #selector(jump(_:)), name: .epubJump, object: nil)
        openTask = Task { [weak self] in
            guard let self, let book = model.books.first(where: { $0.id == self.bookID }), let store = model.store else { return }
            do {
                let directory = store.directory(bookID)
                let publication = try await EPUBService.shared.open(directory.appendingPathComponent("original.epub"))
                try Task.checkCancellation()
                anchors = try JSONDecoder().decode([EPUBAnchor].self, from: Data(contentsOf: directory.appendingPathComponent("epub-map.json")))
                let locator = try book.epubLocator.flatMap { try Locator(json: JSONSerialization.jsonObject(with: $0)) }
                var templates = HTMLDecorationTemplate.defaultTemplates()
                templates["wave"] = HTMLDecorationTemplate(layout: .boxes, element: "<div class='moread-wave'/>", stylesheet: """
                .moread-wave { background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='8' height='4'%3E%3Cpath d='M0 2 Q2 0 4 2 T8 2' fill='none' stroke='%23d67b16' stroke-width='1.3'/%3E%3C/svg%3E"); background-repeat: repeat-x; background-position: bottom; }
                """)
                var config = EPUBNavigatorViewController.Configuration(preferences: preferences,
                    editingActions: EditingAction.defaultActions + [EditingAction(title: "批注", action: #selector(annotate))], decorationTemplates: templates)
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
                spinner.removeFromSuperview()
            } catch is CancellationError {} catch { model.error = error.localizedDescription; spinner.stopAnimating() }
        }
    }
    func navigator(_ navigator: EPUBNavigatorViewController, setupUserScripts controller: WKUserContentController) {
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
        self.fontSize = fontSize; self.lineSpacing = lineSpacing; self.typography = typography; self.paper = paper; navigator?.submitPreferences(preferences)
    }
    func setAnnotations(_ value: [Annotation]) {
        guard value != annotations else { return }
        annotations = value; renderAnnotations()
    }
    private func renderAnnotations() {
        let decorations = annotations.compactMap { annotation -> Decoration? in
            guard let locator = locator(for: annotation.passage) else { return nil }
            let style: Decoration.Style = annotation.style == "wave" ? .init(id: "wave") : annotation.style == "underline" ? .underline(tint: .systemOrange) : .highlight(tint: .systemYellow)
            return Decoration(id: annotation.id.uuidString, locator: locator, style: style)
        }
        navigator?.apply(decorations: decorations, in: "annotations")
    }
    private func locator(for passage: SourcePassage) -> Locator? {
        guard let book = model.books.first(where: { $0.id == bookID }), passage.bookID == bookID,
              let chapter = try? model.store?.chapter(passage.chapter, in: book), passage.isValid(in: chapter, scope: .wholeBook),
              let reader = navigator, reader.publication.readingOrder.indices.contains(passage.chapter) else { return nil }
        if let data = passage.epubLocator, let exact = try? Locator(json: JSONSerialization.jsonObject(with: data)) { return exact }
        let end = passage.offset + passage.text.utf16.count
        let start = TextBoundary.floor(max(0, passage.offset - 80), in: chapter.text)
        let after = TextBoundary.floor(min(chapter.text.utf16.count, end + 80), in: chapter.text)
        let source = chapter.text as NSString
        return Locator(href: reader.publication.readingOrder[passage.chapter].url(), mediaType: .xhtml,
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
            Task { if let locator = try? Locator(jsonString: anchor.locator) { _ = await navigator?.go(to: locator) } }
        }
    }
    func close() {
        openTask?.cancel(); locationTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }
    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        model.perform { onLocation(try JSONSerialization.data(withJSONObject: locator.json)) }
        locationTask?.cancel()
        locationTask = Task { [weak self] in
            guard let self, let reader = self.navigator, let exact = await reader.firstVisibleElementLocator(), !Task.isCancelled else { return }
            guard var book = model.books.first(where: { $0.id == self.bookID }), let position = position(for: exact, book: book) else { return }
            // A paragraph's start is a conservative watermark: text below it stays unread.
            book.record(position: position, visibleEnd: position); model.update(book)
        }
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
    @objc private func annotate() {
        guard let selected = navigator?.currentSelection,
              let book = model.books.first(where: { $0.id == bookID }),
              let position = position(for: selected.locator, book: book),
              let text = selected.locator.text.highlight,
              let chapter = try? model.store?.chapter(position.chapter, in: book) else {
            model.error = "暂时无法准确定位这段原文，请选择更完整的一段再试。"; return
        }
        var passage = SourcePassage(bookID: bookID, chapter: chapter, offset: position.offset, text: text)
        passage.epubLocator = try? JSONSerialization.data(withJSONObject: selected.locator.json)
        onSelection(passage); navigator?.clearSelection()
    }
    @objc private func jump(_ notification: Notification) {
        guard let jump = notification.object as? EPUBJump, jump.bookID == bookID else { return }
        Task {
            do {
                let locator: Locator?
                if let data = jump.locator { locator = try Locator(json: JSONSerialization.jsonObject(with: data)) }
                else if let anchor = anchors.last(where: { $0.chapter == jump.chapter && $0.offset <= jump.offset }) {
                    locator = try Locator(jsonString: anchor.locator)
                } else if let reader = navigator, reader.publication.readingOrder.indices.contains(jump.chapter) {
                    _ = await reader.go(to: reader.publication.readingOrder[jump.chapter]); return
                } else { locator = nil }
                if let locator { _ = await navigator?.go(to: locator) }
            } catch { model.error = error.localizedDescription }
        }
    }
    func navigator(_ navigator: VisualNavigator, didTapAt point: CGPoint) {
        guard abs(point.x - view.bounds.midX) < view.bounds.width / 6 else { return }
        onToggleControls()
    }
    func navigator(_ navigator: Navigator, presentError error: NavigatorError) { model.error = "阅读操作失败，请重新打开这本书。" }
    func navigator(_ navigator: Navigator, didFailToLoadResourceAt href: RelativeURL, withError error: ReadError) { model.error = "书内资源无法读取，请检查 EPUB 文件是否完整。" }
}
