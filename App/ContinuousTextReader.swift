import SwiftUI
import UIKit
import CoreText
import MoReadCore

struct ContinuousTextReader: UIViewControllerRepresentable {
    let bookID: UUID
    let chapterCount: Int
    let currentChapter: Int
    let content: TextReader
    let revision: UUID
    let chapterContent: (Int) -> (Chapter, TextReader)?
    let onRead: (ReadingPosition, ReadingPosition, SourcePassage?) -> Void
    func makeUIViewController(context: Context) -> ContinuousTextController { ContinuousTextController(self) }
    func updateUIViewController(_ controller: ContinuousTextController, context: Context) { controller.update(self) }
    static func dismantleUIViewController(_ controller: ContinuousTextController, coordinator: ()) { controller.close() }
}

@MainActor
final class ContinuousTextController: ReaderKeyboardController, UITableViewDataSource, UITableViewDelegate, UIGestureRecognizerDelegate {
    private var parentReader: ContinuousTextReader
    private let table = UITableView(frame: .zero, style: .plain)
    private let backdrop = ReaderTextView(frame: .zero)
    private var cache: [Int: (Chapter, TextReader)] = [:]
    private var heights: [Int: CGFloat] = [:]
    private lazy var measuringCell = ContinuousChapterCell(style: .default, reuseIdentifier: nil)
    private let owner = UUID()
    private var size = CGSize.zero
    private var generation = UUID()
    private var restoring = true
    private var active = true
    private var reportPending = false
    private var position: ReadingPosition
    private var rotationAnchor: ReadingPosition?
    private var rotationID = UUID()

    init(_ parent: ContinuousTextReader) {
        parentReader = parent
        position = ReadingPosition(chapter: parent.currentChapter, offset: parent.content.offset)
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var keyboardReady: Bool { active && parentReader.content.isReading }
    override func turnWithKey(_ forward: Bool) {
        guard active, !restoring, parentReader.content.isReading,
              table.visibleCells.allSatisfy({ (($0 as? ContinuousChapterCell)?.textView.selectedRange.length ?? 0) == 0 }) else { return }
        let step = table.bounds.height * 0.9 * (forward ? 1 : -1)
        table.setContentOffset(CGPoint(x: 0, y: min(max(0, table.contentSize.height - table.bounds.height), max(0, table.contentOffset.y + step))), animated: !UIAccessibility.isReduceMotionEnabled)
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        keyboardSession = parentReader.content.autoRead
        table.dataSource = self; table.delegate = self
        table.separatorStyle = .none; table.allowsSelection = false
        table.contentInsetAdjustmentBehavior = .never
        table.rowHeight = UITableView.automaticDimension
        table.register(ContinuousChapterCell.self, forCellReuseIdentifier: "chapter")
        table.accessibilityIdentifier = "continuous-reader"
        backdrop.scrollsToTop = false; backdrop.isUserInteractionEnabled = false; backdrop.isAccessibilityElement = false; backdrop.accessibilityElementsHidden = true; table.backgroundView = backdrop
        view.addSubview(table)
        table.addGestureRecognizer(AutoReadTouch(parentReader.content.autoRead))
        let tap = UITapGestureRecognizer(target: self, action: #selector(toggleControls(_:)))
        tap.cancelsTouchesInView = false; tap.delegate = self; table.addGestureRecognizer(tap)
        parentReader.content.autoRead.attach(owner) { [weak self] distance in
            guard let self, active, !restoring, parentReader.content.isReading,
                  !table.visibleCells.isEmpty, table.visibleCells.allSatisfy({ ($0 as? ContinuousChapterCell)?.content != nil }) else { return .waiting }
            guard distance > 0 else { return .ready }
            let bottom = max(0, table.contentSize.height - table.bounds.height)
            if table.contentOffset.y >= bottom - 0.5,
               table.indexPathsForVisibleRows?.contains(IndexPath(row: parentReader.chapterCount - 1, section: 0)) == true { return .end }
            table.setContentOffset(CGPoint(x: 0, y: min(bottom, table.contentOffset.y + distance)), animated: false)
            report(); return .ready
        }
        updatePaper()
    }
    func close() {
        NotificationCenter.default.removeObserver(self)
        active = false; generation = UUID(); parentReader.content.autoRead.detach(owner)
        table.delegate = nil; table.dataSource = nil; cache.removeAll()
    }
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        // UIKit can adjust table offsets throughout rotation; restore after its final layout.
        rotationAnchor = rotationAnchor ?? position
        generation = UUID(); restoring = true
        let token = UUID(); rotationID = token
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            guard let self, active, rotationID == token else { return }
            view.layoutIfNeeded()
            let target = rotationAnchor ?? position
            rotationAnchor = nil
            reload(at: target)
        }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        table.frame = view.bounds
        guard view.bounds.width > 100, view.bounds.height > 100, size != view.bounds.size else { return }
        if size != .zero { parentReader.content.autoRead.pause("排版改变，已暂停") }
        size = view.bounds.size; table.estimatedRowHeight = size.height; heights.removeAll()
        guard rotationAnchor == nil else { return }
        reload(at: position)
    }
    func update(_ parent: ContinuousTextReader) {
        let old = parentReader
        parentReader = parent
        updateKeyboard()
        loadViewIfNeeded()
        updatePaper()
        let navigation = old.content.navigationID != parent.content.navigationID
        let style = old.content.font != parent.content.font || old.content.fontSize != parent.content.fontSize
            || old.content.presentation.chineseConversionMode != parent.content.presentation.chineseConversionMode
            || old.content.lineSpacing != parent.content.lineSpacing || old.content.typography != parent.content.typography
            || old.content.ink != parent.content.ink || old.content.wordGlosses != parent.content.wordGlosses || old.revision != parent.revision
        if navigation || style {
            if style, !navigation { parent.content.autoRead.pause("排版改变，已暂停") }
            cache.removeAll()
            if style { heights.removeAll() }
            reload(at: navigation ? ReadingPosition(chapter: parent.currentChapter, offset: parent.content.offset) : position)
        } else if old.content.speechRange != parent.content.speechRange {
            cache.removeAll()
            for case let cell as ContinuousChapterCell in table.visibleCells {
                guard let path = table.indexPath(for: cell), let data = item(path.row) else { continue }
                cell.configure(chapter: data.0, content: data.1, bookID: parent.bookID, minimumHeight: size.height, width: size.width)
                cell.positionViewport(at: table.contentOffset.y - table.rectForRow(at: path).minY)
                if let range = data.1.speechDisplayRanges.first {
                    let rect = cell.rect(forDisplayOffset: range.location)
                    table.scrollRectToVisible(cell.textView.convert(rect, to: table), animated: false)
                }
            }
        }
        if parent.content.isReading, !old.content.isReading { report() }
    }
    private func updatePaper() {
        let content = parentReader.content
        backdrop.setPaper(content.paper, image: content.backgroundImage, opacity: content.typography.backgroundOpacity ?? 0.25)
    }
    private func item(_ index: Int) -> (Chapter, TextReader)? {
        if let value = cache[index] { return value }
        guard let value = parentReader.chapterContent(index) else { return nil }
        cache[index] = value; return value
    }
    private func reload(at target: ReadingPosition) {
        position = target; generation = UUID(); restoring = true
        if rotationAnchor != nil { rotationAnchor = target; return }
        guard size != .zero, parentReader.chapterCount > 0 else { return }
        let token = generation
        table.reloadData(); table.layoutIfNeeded()
        let path = IndexPath(row: min(target.chapter, parentReader.chapterCount - 1), section: 0)
        table.scrollToRow(at: path, at: .top, animated: false); table.layoutIfNeeded()
        DispatchQueue.main.async { [weak self] in
            guard let self, active, generation == token else { return }
            table.layoutIfNeeded()
            if let cell = table.cellForRow(at: path) as? ContinuousChapterCell, let content = cell.content {
                let offset = content.presentation.displayOffset(forSource: target.offset)
                let rect = cell.rect(forDisplayOffset: offset)
                let y = target.offset == 0 ? table.rectForRow(at: path).minY : cell.textView.convert(rect.origin, to: table).y
                table.setContentOffset(CGPoint(x: 0, y: min(max(0, table.contentSize.height - table.bounds.height), max(0, y))), animated: false)
            }
            positionCells(); restoring = false; report()
        }
    }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { parentReader.chapterCount }
    func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        if let height = heights[indexPath.row] { return height }
        // Exact neighboring heights keep a jump stable when UIKit materializes adjacent chapters.
        if abs(indexPath.row - position.chapter) <= 1, size.width > 100, let data = item(indexPath.row) {
            measuringCell.configure(chapter: data.0, content: data.1, bookID: parentReader.bookID, minimumHeight: size.height, width: size.width)
            heights[indexPath.row] = measuringCell.measuredHeight
            return measuringCell.measuredHeight
        }
        return max(1, size.height)
    }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "chapter", for: indexPath) as! ContinuousChapterCell
        if let data = item(indexPath.row) { cell.configure(chapter: data.0, content: data.1, bookID: parentReader.bookID, minimumHeight: size.height, width: size.width) }
        else { cell.showError(minimumHeight: size.height) }
        heights[indexPath.row] = cell.measuredHeight
        return cell
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { positionCells(); report() }
    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        (cell as? ContinuousChapterCell)?.positionViewport(at: table.contentOffset.y - table.rectForRow(at: indexPath).minY)
    }
    private func positionCells() {
        for case let cell as ContinuousChapterCell in table.visibleCells {
            guard let path = table.indexPath(for: cell) else { continue }
            cell.positionViewport(at: table.contentOffset.y - table.rectForRow(at: path).minY)
        }
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { parentReader.content.autoRead.pause("触摸后已暂停") }
    private func report() {
        guard active, !restoring, parentReader.content.isReading, !reportPending else { return }
        reportPending = true
        let token = generation
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            reportPending = false
            guard active, !restoring, generation == token, parentReader.content.isReading else { return }
            let paths = (table.indexPathsForVisibleRows ?? []).sorted()
            var first: ReadingPosition?, end: ReadingPosition?, passage: SourcePassage?
            for path in paths {
                guard let cell = table.cellForRow(at: path) as? ContinuousChapterCell, let content = cell.content else { return }
                let visible = cell.textView.convert(table.bounds, from: table).intersection(cell.textView.bounds)
                guard !visible.isNull, visible.height > 1 else { continue }
                let range = cell.sourceRange(in: visible)
                if first == nil { first = ReadingPosition(chapter: path.row, offset: range?.location ?? content.presentation.source.utf16.count) }
                if let range, range.length > 0 {
                    end = ReadingPosition(chapter: path.row, offset: NSMaxRange(range))
                    if passage == nil { passage = cell.passage(range) }
                }
            }
            guard let first else { return }
            position = first
            cache = cache.filter { abs($0.key - first.chapter) <= 1 }
            parentReader.onRead(first, max(first, end ?? first), passage)
        }
    }
    @objc private func toggleControls(_ tap: UITapGestureRecognizer) {
        for case let cell as ContinuousChapterCell in table.visibleCells where cell.textView.hasVocabularyTag(at: tap.location(in: cell.textView)) { return }
        guard active, !restoring, parentReader.content.isReading, !table.isDecelerating,
              table.visibleCells.allSatisfy({ (($0 as? ContinuousChapterCell)?.textView.selectedRange.length ?? 0) == 0 }) else { return }
        if let zones = parentReader.content.tapZones {
            let point = tap.location(in: view)
            let action = zones.action(x: point.x, y: point.y, width: view.bounds.width, height: view.bounds.height)
            switch action {
            case .previousPage, .nextPage:
                let step = table.bounds.height * 0.9 * (action == .previousPage ? -1 : 1)
                table.setContentOffset(CGPoint(x: 0, y: min(max(0, table.contentSize.height - table.bounds.height), max(0, table.contentOffset.y + step))), animated: !UIAccessibility.isReduceMotionEnabled)
            default: parentReader.content.onTapAction(action)
            }
        } else if abs(tap.location(in: table).x - table.bounds.midX) < table.bounds.width / 6 { parentReader.content.onToggleControls() }
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

@MainActor
private final class ContinuousChapterCell: UITableViewCell, UITextViewDelegate {
    let textView: UITextView
    private var chapterHeight: NSLayoutConstraint!
    private var viewportHeight: NSLayoutConstraint!
    private var viewportTop: NSLayoutConstraint!
    private(set) var content: TextReader?
    private var source: SourcePassage?
    var measuredHeight: CGFloat { chapterHeight.constant }
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        let storage = NSTextStorage(), manager = AnnotationLayoutManager(), container = NSTextContainer(size: .zero)
        manager.addTextContainer(container); storage.addLayoutManager(manager)
        textView = ContinuousChapterTextView(frame: .zero, textContainer: container)
        // UITextView enables width tracking during initialization, before the cell has its final frame.
        container.widthTracksTextView = false; container.heightTracksTextView = false
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear; contentView.backgroundColor = .clear; contentView.clipsToBounds = true; selectionStyle = .none
        textView.backgroundColor = .clear; textView.isEditable = false
        textView.showsVerticalScrollIndicator = false; textView.scrollsToTop = false
        textView.contentInsetAdjustmentBehavior = .never
        textView.delegate = self; textView.accessibilityIdentifier = "reader-text"
        textView.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(textView)
        chapterHeight = contentView.heightAnchor.constraint(equalToConstant: 1)
        chapterHeight.priority = .init(999)
        viewportHeight = textView.heightAnchor.constraint(equalToConstant: 1)
        viewportTop = textView.topAnchor.constraint(equalTo: contentView.topAnchor)
        NSLayoutConstraint.activate([textView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor), textView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor), viewportTop, viewportHeight, chapterHeight])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func prepareForReuse() { super.prepareForReuse(); content = nil; source = nil; textView.attributedText = nil }
    func configure(chapter: Chapter, content: TextReader, bookID: UUID, minimumHeight: CGFloat, width: CGFloat) {
        self.content = content; viewportHeight.constant = max(1, minimumHeight)
        textView.frame.size = CGSize(width: max(1, width), height: max(1, minimumHeight))
        source = SourcePassage(bookID: bookID, chapter: chapter, offset: 0, text: "")
        textView.textContainerInset = content.typography.insets
        textView.attributedText = content.attributedText
        textView.layoutIfNeeded()
        textView.textContainer.size = CGSize(width: max(1, width - textView.textContainerInset.left - textView.textContainerInset.right), height: .greatestFiniteMagnitude)
        textView.layoutManager.ensureLayout(for: textView.textContainer)
        chapterHeight.constant = max(minimumHeight, ceil(textView.layoutManager.usedRect(for: textView.textContainer).maxY + textView.textContainerInset.top + textView.textContainerInset.bottom))
        for range in content.speechDisplayRanges { textView.textStorage.addAttribute(.backgroundColor, value: UIColor.systemTeal.withAlphaComponent(0.3), range: range) }
        textView.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "显示或收起阅读工具", actionHandler: { _ in content.onToggleControls(); return true })]
    }
    func showError(minimumHeight: CGFloat) {
        content = nil; source = nil; chapterHeight.constant = max(1, minimumHeight); viewportHeight.constant = max(1, minimumHeight)
        textView.text = "正文暂不可用，请重新打开这本书。"
    }
    // The row spans the chapter, while TextKit draws only a viewport-sized surface.
    func positionViewport(at offset: CGFloat) {
        let y = min(max(0, chapterHeight.constant - viewportHeight.constant), max(0, offset))
        viewportTop.constant = y; contentView.layoutIfNeeded()
        textView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
    }
    func rect(forDisplayOffset offset: Int) -> CGRect {
        let index = min(max(0, offset), max(0, textView.textStorage.length - 1))
        let glyph = textView.layoutManager.glyphRange(forCharacterRange: NSRange(location: index, length: textView.textStorage.length > 0 ? 1 : 0), actualCharacterRange: nil)
        return textView.layoutManager.boundingRect(forGlyphRange: glyph, in: textView.textContainer).offsetBy(dx: textView.textContainerInset.left, dy: textView.textContainerInset.top)
    }
    func sourceRange(in visible: CGRect) -> NSRange? {
        guard let content else { return nil }
        let rect = visible.offsetBy(dx: -textView.textContainerInset.left, dy: -textView.textContainerInset.top)
        let glyphs = textView.layoutManager.glyphRange(forBoundingRect: rect, in: textView.textContainer)
        // TextKit includes the previous line when the viewport begins in paragraph spacing.
        var visibleGlyphs: NSRange?
        textView.layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, line, _ in
            let range = NSIntersectionRange(line, glyphs)
            guard range.length > 0 else { return }
            var bounds = self.textView.layoutManager.boundingRect(forGlyphRange: range, in: self.textView.textContainer)
            let index = self.textView.layoutManager.characterIndexForGlyph(at: range.location)
            let paragraph = self.textView.textStorage.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle
            bounds.size.height = max(0, bounds.height - (paragraph?.lineSpacing ?? 0))
            guard bounds.intersects(rect) else { return }
            if bounds.minY < rect.minY || bounds.maxY > rect.maxY {
                let characters = self.textView.layoutManager.characterRange(forGlyphRange: range, actualGlyphRange: nil)
                let text = self.textView.textStorage.attributedSubstring(from: characters)
                let ink = CTLineGetBoundsWithOptions(CTLineCreateWithAttributedString(text), .useGlyphPathBounds)
                let baseline = self.textView.layoutManager.lineFragmentRect(forGlyphAt: range.location, effectiveRange: nil).minY + self.textView.layoutManager.location(forGlyphAt: range.location).y
                if !ink.isEmpty { bounds.origin.y = baseline - ink.maxY; bounds.size.height = ink.height }
                guard bounds.intersects(rect) else { return }
            }
            visibleGlyphs = visibleGlyphs.map { NSUnionRange($0, range) } ?? range
        }
        guard let visibleGlyphs else { return nil }
        let range = textView.layoutManager.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
        guard range.length > 0 else { return nil }
        return content.presentation.sourceRange(forDisplay: range)
    }
    func passage(_ range: NSRange) -> SourcePassage? {
        guard let content, var source else { return nil }
        source.offset = range.location; source.text = (content.presentation.source as NSString).substring(with: range)
        return source
    }
    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let actions = content?.selectionActions(for: range) else { return nil }
        return UIMenu(children: suggestedActions + actions)
    }
    func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
        if case .tag("moread-vocabulary") = textItem.content, let range = textView.vocabularyRange(at: textItem.range.location) { return content?.selectionActions(for: range).last }
        return defaultAction
    }
}

private final class ContinuousChapterTextView: UITextView {
    // Keep native text tiling while the table handles dragging.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer !== panGestureRecognizer && super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}
