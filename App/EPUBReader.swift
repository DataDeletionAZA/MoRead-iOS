import SwiftUI
import UIKit
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
        var anchors: [EPUBAnchor] = []
        var totalLength = 0
        if let iterator = publication.content()?.iterator() {
            while let element = try await iterator.next() {
                try Task.checkCancellation()
                guard let textual = element as? TextualContentElement, !textual.text.isEmpty,
                      let index = paths.firstIndex(of: element.locator.href.string.components(separatedBy: "#")[0]) else { continue }
                let text = textual.text
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
    let night: Bool
    let onLocation: (Data) -> Void
    let onSelection: (SourcePassage) -> Void
    @EnvironmentObject private var model: LibraryModel

    func makeUIViewController(context: Context) -> EPUBHostController {
        EPUBHostController(book: book, model: model, fontSize: fontSize, night: night, onLocation: onLocation, onSelection: onSelection)
    }
    func updateUIViewController(_ controller: EPUBHostController, context: Context) { controller.setPreferences(fontSize: fontSize, night: night) }
    static func dismantleUIViewController(_ controller: EPUBHostController, coordinator: ()) { controller.close() }
}

@MainActor
final class EPUBHostController: UIViewController, EPUBNavigatorDelegate {
    private let bookID: UUID
    private let model: LibraryModel
    private let onLocation: (Data) -> Void
    private let onSelection: (SourcePassage) -> Void
    private var navigator: EPUBNavigatorViewController?
    private var anchors: [EPUBAnchor] = []
    private var openTask: Task<Void, Never>?
    private var locationTask: Task<Void, Never>?
    private var fontSize: Double
    private var night: Bool

    init(book: Book, model: LibraryModel, fontSize: Double, night: Bool, onLocation: @escaping (Data) -> Void, onSelection: @escaping (SourcePassage) -> Void) {
        bookID = book.id; self.model = model; self.fontSize = fontSize; self.night = night
        self.onLocation = onLocation; self.onSelection = onSelection
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
            guard let self, let book = model.books.first(where: { $0.id == bookID }), let store = model.store else { return }
            do {
                let directory = store.directory(bookID)
                let publication = try await EPUBService.shared.open(directory.appendingPathComponent("original.epub"))
                try Task.checkCancellation()
                anchors = try JSONDecoder().decode([EPUBAnchor].self, from: Data(contentsOf: directory.appendingPathComponent("epub-map.json")))
                let locator = try book.epubLocator.flatMap { try Locator(json: JSONSerialization.jsonObject(with: $0)) }
                let config = EPUBNavigatorViewController.Configuration(preferences: preferences,
                    editingActions: EditingAction.defaultActions + [EditingAction(title: "批注", action: #selector(annotate))])
                let reader = try EPUBNavigatorViewController(publication: publication, initialLocation: locator, config: config)
                navigator = reader; reader.delegate = self
                addChild(reader); reader.view.frame = view.bounds
                reader.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                view.addSubview(reader.view); reader.didMove(toParent: self)
                spinner.removeFromSuperview()
            } catch is CancellationError {} catch { model.error = error.localizedDescription; spinner.stopAnimating() }
        }
    }
    private var preferences: EPUBPreferences { EPUBPreferences(fontSize: fontSize / 16, scroll: false, theme: night ? .dark : .sepia) }
    func setPreferences(fontSize: Double, night: Bool) {
        guard fontSize != self.fontSize || night != self.night else { return }
        self.fontSize = fontSize; self.night = night; navigator?.submitPreferences(preferences)
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
            guard var book = model.books.first(where: { $0.id == bookID }), let position = position(for: exact, book: book) else { return }
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
        let passage = SourcePassage(bookID: bookID, chapter: chapter, offset: position.offset, text: text)
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
    func navigator(_ navigator: Navigator, presentError error: NavigatorError) { model.error = "阅读操作失败，请重新打开这本书。" }
    func navigator(_ navigator: Navigator, didFailToLoadResourceAt href: RelativeURL, withError error: ReadError) { model.error = "书内资源无法读取，请检查 EPUB 文件是否完整。" }
}
