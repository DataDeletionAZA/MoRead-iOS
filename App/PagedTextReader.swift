import SwiftUI
import UIKit
import MoReadCore

enum ReaderPageMode: String, CaseIterable {
    case scroll, simulation, cover, slide, none
    var label: String {
        switch self { case .scroll: return "上下滚动"; case .simulation: return "仿真翻页"; case .cover: return "覆盖翻页"; case .slide: return "滑动翻页"; case .none: return "无动画翻页" }
    }
}

struct PagedTextReader: UIViewControllerRepresentable {
    let content: TextReader
    let mode: ReaderPageMode
    let hasPreviousChapter: Bool
    let hasNextChapter: Bool
    let onChapter: (Int) -> Void
    func makeUIViewController(context: Context) -> TextPagesController { TextPagesController(self) }
    func updateUIViewController(_ controller: TextPagesController, context: Context) { controller.update(self) }
    static func dismantleUIViewController(_ controller: TextPagesController, coordinator: ()) { controller.deactivate() }
}

@MainActor
final class TextPagesController: UIViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
    private var parentReader: PagedTextReader
    private var textStorage = NSTextStorage()
    private var layout = AnnotationLayoutManager()
    private var baseText = NSAttributedString(string: "")
    private var containers: [NSTextContainer] = []
    private var ranges: [NSRange] = []
    private var pages: [Int: TextPageController] = [:]
    private var pager: UIPageViewController?
    private var visible: TextPageController?
    private let pageHost = UIView()
    private let previous = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let counter = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var pageIndex = 0
    private var anchor = 0
    private var laidOutSize = CGSize.zero
    private var generation = UUID()
    private var pagination: Task<Void, Never>?
    private var active = true
    private var transitioning = false
    private var needsPagination = true
    private var dragPage: TextPageController?
    private var dragDirection = 0

    init(_ parent: PagedTextReader) { parentReader = parent; anchor = parent.content.offset; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func deactivate() { active = false; cancel(); pager?.dataSource = nil; pager?.delegate = nil }
    func cancel() { generation = UUID(); pagination?.cancel(); pagination = nil }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = parentReader.content.paper
        pageHost.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pageHost)
        previous.setTitle("上一页", for: .normal); nextButton.setTitle("下一页", for: .normal)
        previous.accessibilityIdentifier = "reader-previous-page"; nextButton.accessibilityIdentifier = "reader-next-page"
        previous.addTarget(self, action: #selector(back), for: .touchUpInside); nextButton.addTarget(self, action: #selector(forward), for: .touchUpInside)
        counter.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular); counter.textAlignment = .center; counter.textColor = .secondaryLabel
        counter.accessibilityIdentifier = "reader-page-number"
        let footer = UIStackView(arrangedSubviews: [previous, counter, nextButton]); footer.axis = .horizontal; footer.distribution = .equalSpacing
        footer.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(footer)
        NSLayoutConstraint.activate([
            pageHost.leadingAnchor.constraint(equalTo: view.leadingAnchor), pageHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pageHost.topAnchor.constraint(equalTo: view.topAnchor), pageHost.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22), footer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor), footer.heightAnchor.constraint(equalToConstant: 44)
        ])
        spinner.translatesAutoresizingMaskIntoConstraints = false; pageHost.addSubview(spinner)
        spinner.accessibilityLabel = "正在分页"
        NSLayoutConstraint.activate([spinner.centerXAnchor.constraint(equalTo: pageHost.centerXAnchor), spinner.centerYAnchor.constraint(equalTo: pageHost.centerYAnchor)])
        if parentReader.mode == .simulation || parentReader.mode == .slide {
            let style: UIPageViewController.TransitionStyle = parentReader.mode == .simulation ? .pageCurl : .scroll
            let pager = UIPageViewController(transitionStyle: style, navigationOrientation: .horizontal)
            self.pager = pager; pager.dataSource = self; pager.delegate = self
            addChild(pager); pageHost.insertSubview(pager.view, belowSubview: spinner); pager.didMove(toParent: self)
        } else {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(drag(_:))); pan.delegate = self
            pageHost.addGestureRecognizer(pan)
        }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        pager?.view.frame = pageHost.bounds
        if !transitioning { visible?.view.frame = pageHost.bounds }
        guard pageHost.bounds.width > 100, pageHost.bounds.height > 100 else { return }
        if laidOutSize != pageHost.bounds.size || needsPagination { repaginate() }
    }
    func update(_ parent: PagedTextReader) {
        let old = parentReader.content
        parentReader = parent
        let content = parent.content
        let navigation = old.navigationID != content.navigationID
        let geometry = old.text != content.text || old.fontSize != content.fontSize || old.lineSpacing != content.lineSpacing || old.typography != content.typography
        if navigation { anchor = content.offset; if transitioning { needsPagination = true } }
        view.backgroundColor = content.paper
        if geometry { needsPagination = true; view.setNeedsLayout() }
        else if needsPagination || pagination != nil { if navigation { needsPagination = true; view.setNeedsLayout() } }
        else {
            if old.annotations != content.annotations || old.night != content.night {
                baseText = content.attributedText; textStorage.setAttributedString(baseText)
            }
            for page in pages.values { page.view.backgroundColor = content.paper; page.textView?.backgroundColor = content.paper }
            if old.speechRange != content.speechRange || old.annotations != content.annotations || old.night != content.night {
                if let previous = old.speechRange, NSMaxRange(previous) <= baseText.length {
                    baseText.enumerateAttributes(in: previous) { attributes, range, _ in textStorage.setAttributes(attributes, range: range) }
                }
                if let range = content.speechRange, range.location >= 0, NSMaxRange(range) <= textStorage.length {
                    textStorage.addAttribute(.backgroundColor, value: UIColor.systemTeal.withAlphaComponent(0.3), range: range)
                    if let index = index(containing: range.location), index != pageIndex { display(index, animated: false, preserving: range.location) }
                }
            }
            if navigation, let index = index(containing: anchor) { display(index, animated: false, preserving: anchor) }
            if content.isReading, !old.isReading { report() }
        }
    }
    private func repaginate() {
        guard !transitioning else { needsPagination = true; return }
        cancel(); needsPagination = false; laidOutSize = pageHost.bounds.size
        let token = generation
        let content = parentReader.content
        baseText = content.attributedText
        let storage = NSTextStorage(attributedString: baseText)
        let manager = AnnotationLayoutManager(); storage.addLayoutManager(manager)
        let insets = content.typography.insets
        let size = CGSize(width: laidOutSize.width - insets.left - insets.right, height: laidOutSize.height - insets.top - insets.bottom)
        guard size.width > 10, size.height > 0 else { counter.text = "当前窗口太小，请放大窗口"; return }
        spinner.startAnimating(); previous.isEnabled = false; nextButton.isEnabled = false; counter.text = "正在分页…"
        pager?.view.isHidden = true; visible?.view.isHidden = true
        pagination = Task { [weak self] in
            var containers: [NSTextContainer] = []; var ranges: [NSRange] = []
            var end = 0
            repeat {
                guard !Task.isCancelled, let self, self.generation == token else { return }
                let container = NSTextContainer(size: size); container.widthTracksTextView = false; container.heightTracksTextView = false
                manager.addTextContainer(container)
                let glyphs = manager.glyphRange(for: container)
                let range = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
                guard range.location == end, NSMaxRange(range) <= storage.length, NSMaxRange(range) > end || storage.length == 0 else {
                    self.spinner.stopAnimating(); self.counter.text = "当前窗口太小，请放大窗口"; self.pagination = nil; return
                }
                containers.append(container); ranges.append(range); end = NSMaxRange(range)
                if containers.count.isMultiple(of: 8) { await Task.yield() }
            } while end < storage.length
            guard let self, !Task.isCancelled, self.generation == token, !self.needsPagination else { return }
            self.baseText = self.parentReader.content.attributedText; storage.setAttributedString(self.baseText)
            self.visible?.willMove(toParent: nil); self.visible?.view.removeFromSuperview(); self.visible?.removeFromParent(); self.visible = nil
            self.pages = [:]; self.textStorage = storage; self.layout = manager; self.containers = containers; self.ranges = ranges
            self.pagination = nil; self.spinner.stopAnimating(); self.pager?.view.isHidden = false
            if let range = self.parentReader.content.speechRange, range.location >= 0, NSMaxRange(range) <= storage.length {
                storage.addAttribute(.backgroundColor, value: UIColor.systemTeal.withAlphaComponent(0.3), range: range)
            }
            self.display(self.index(containing: self.anchor) ?? 0, animated: false, preserving: self.anchor)
        }
    }
    private func index(containing offset: Int) -> Int? {
        guard !ranges.isEmpty else { return nil }
        let safe = TextBoundary.floor(offset, in: parentReader.content.text)
        return ranges.firstIndex { NSMaxRange($0) > safe } ?? ranges.count - 1
    }
    private func page(_ index: Int) -> TextPageController? {
        guard ranges.indices.contains(index) || (index == -1 && parentReader.hasPreviousChapter) || (index == ranges.count && parentReader.hasNextChapter) else { return nil }
        if let page = pages[index] { return page }
        let page: TextPageController
        if ranges.indices.contains(index) {
            page = TextPageController(index: index, container: containers[index], range: ranges[index], content: parentReader.content)
            page.onSelection = { [weak self] range in self?.parentReader.content.onSelection(range) }
            page.turnPage = { [weak self] direction in self?.turn(direction) }
        } else { page = TextPageController(index: index, message: index < 0 ? "上一章" : "下一章", paper: parentReader.content.paper) }
        pages[index] = page
        return page
    }
    private func display(_ index: Int, animated: Bool, preserving offset: Int? = nil) {
        guard active, !transitioning, pagination == nil, let target = page(index) else { return }
        if !ranges.indices.contains(index) { parentReader.onChapter(index < 0 ? -1 : 1); return }
        let direction = index >= pageIndex ? 1 : -1
        let token = generation
        if let pager {
            transitioning = animated
            pager.setViewControllers([target], direction: direction > 0 ? .forward : .reverse, animated: animated && !UIAccessibility.isReduceMotionEnabled) { [weak self] finished in
                guard let self, self.generation == token else { return }; self.transitioning = false
                if finished, !self.needsPagination { self.commit(index, preserving: offset) }
                if self.needsPagination { self.view.setNeedsLayout() }
            }
        } else if animated, parentReader.mode == .cover, !UIAccessibility.isReduceMotionEnabled, visible != nil {
            beginCover(target, direction: direction)
            finishCover(commit: true)
        } else {
            visible?.willMove(toParent: nil); visible?.view.removeFromSuperview(); visible?.removeFromParent()
            addChild(target); target.view.frame = pageHost.bounds; pageHost.insertSubview(target.view, belowSubview: spinner); target.didMove(toParent: self)
            visible = target; commit(index, preserving: offset)
        }
    }
    private func commit(_ index: Int, preserving offset: Int? = nil) {
        guard active else { return }
        guard ranges.indices.contains(index) else { parentReader.onChapter(index < 0 ? -1 : 1); return }
        pageIndex = index
        anchor = TextBoundary.floor(min(NSMaxRange(ranges[index]), max(ranges[index].location, offset ?? ranges[index].location)), in: parentReader.content.text)
        counter.text = "本章 \(index + 1) / \(ranges.count) 页"
        previous.isEnabled = index > 0 || parentReader.hasPreviousChapter; nextButton.isEnabled = index + 1 < ranges.count || parentReader.hasNextChapter
        pages = pages.filter { abs($0.key - index) <= 1 }
        report()
    }
    private func report() {
        guard active, parentReader.content.isReading, ranges.indices.contains(pageIndex) else { return }
        let range = ranges[pageIndex]; let token = generation; let position = anchor
        let navigation = parentReader.content.navigationID; let callback = parentReader.content.onPosition
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active, self.generation == token, !self.needsPagination, self.anchor == position,
                  self.parentReader.content.navigationID == navigation, self.parentReader.content.isReading else { return }
            callback(position, NSMaxRange(range))
        }
    }
    @objc private func back() { turn(-1) }
    @objc private func forward() { turn(1) }
    private func turn(_ direction: Int) { display(pageIndex + direction, animated: parentReader.mode != .none) }
    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? { (viewController as? TextPageController).flatMap { page($0.index - 1) } }
    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? { (viewController as? TextPageController).flatMap { page($0.index + 1) } }
    func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) { transitioning = true }
    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        transitioning = false
        if completed, let page = pageViewController.viewControllers?.first as? TextPageController { commit(page.index) }
        if needsPagination { view.setNeedsLayout() }
    }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard !transitioning, pagination == nil, visible?.textView?.selectedRange.length ?? 0 == 0, let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
        let velocity = pan.velocity(in: pageHost)
        return abs(velocity.x) > abs(velocity.y)
    }
    @objc private func drag(_ pan: UIPanGestureRecognizer) {
        let delta = pan.translation(in: pageHost).x
        switch pan.state {
        case .began:
            dragDirection = pan.velocity(in: pageHost).x < 0 ? 1 : -1
            if parentReader.mode == .cover, !UIAccessibility.isReduceMotionEnabled, let target = page(pageIndex + dragDirection) { beginCover(target, direction: dragDirection) }
        case .changed:
            guard let target = dragPage else { return }
            let distance = min(pageHost.bounds.width, max(0, delta * CGFloat(-dragDirection)))
            if dragDirection > 0 { target.view.transform = CGAffineTransform(translationX: pageHost.bounds.width - distance, y: 0) }
            else { visible?.view.transform = CGAffineTransform(translationX: distance, y: 0) }
        case .ended, .cancelled:
            let commit = pan.state == .ended && (delta * CGFloat(-dragDirection) > pageHost.bounds.width * 0.2 || pan.velocity(in: pageHost).x * CGFloat(-dragDirection) > 400)
            if dragPage != nil { finishCover(commit: commit) }
            else if commit { turn(dragDirection) }
        default: break
        }
    }
    private func beginCover(_ target: TextPageController, direction: Int) {
        guard let visible else { return }
        transitioning = true; dragPage = target; dragDirection = direction
        addChild(target); target.view.frame = pageHost.bounds
        pageHost.insertSubview(target.view, belowSubview: direction > 0 ? spinner : visible.view); target.didMove(toParent: self)
        target.view.transform = direction > 0 ? CGAffineTransform(translationX: pageHost.bounds.width, y: 0) : .identity
        let top = direction > 0 ? target.view! : visible.view!
        top.layer.shadowColor = UIColor.black.cgColor; top.layer.shadowOpacity = 0.18; top.layer.shadowRadius = 8
    }
    private func finishCover(commit: Bool) {
        guard let target = dragPage, let old = visible else { return }
        UIView.animate(withDuration: 0.22, animations: {
            if self.dragDirection > 0 { target.view.transform = commit ? .identity : CGAffineTransform(translationX: self.pageHost.bounds.width, y: 0) }
            else { old.view.transform = commit ? CGAffineTransform(translationX: self.pageHost.bounds.width, y: 0) : .identity }
        }, completion: { _ in
            let removed = commit ? old : target
            removed.willMove(toParent: nil); removed.view.removeFromSuperview(); removed.removeFromParent()
            old.view.transform = .identity; target.view.transform = .identity; old.view.layer.shadowOpacity = 0; target.view.layer.shadowOpacity = 0
            if commit { self.visible = target }
            self.dragPage = nil; self.transitioning = false
            if commit { self.commit(target.index) }
            if self.needsPagination { self.view.setNeedsLayout() }
        })
    }
}

@MainActor
private final class TextPageController: UIViewController, UITextViewDelegate {
    let index: Int
    let range: NSRange
    var textView: UITextView?
    var onSelection: ((NSRange) -> Void)?
    var turnPage: ((Int) -> Void)?
    init(index: Int, container: NSTextContainer, range: NSRange, content: TextReader) {
        self.index = index; self.range = range
        super.init(nibName: nil, bundle: nil)
        let text = UITextView(frame: .zero, textContainer: container)
        text.isEditable = false; text.isSelectable = true; text.isScrollEnabled = false
        container.widthTracksTextView = false; container.heightTracksTextView = false
        text.contentInsetAdjustmentBehavior = .never
        text.textContainerInset = content.typography.insets
        text.delegate = self; text.backgroundColor = content.paper
        text.accessibilityIdentifier = "reader-text"
        text.accessibilityLabel = "第 \(index + 1) 页正文"
        text.accessibilityValue = (content.text as NSString).substring(with: range)
        text.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "上一页", actionHandler: { [weak self] _ in self?.turnPage?(-1); return true }), UIAccessibilityCustomAction(name: "下一页", actionHandler: { [weak self] _ in self?.turnPage?(1); return true })]
        textView = text; view = text
    }
    init(index: Int, message: String, paper: UIColor) {
        self.index = index; range = NSRange(location: 0, length: 0)
        super.init(nibName: nil, bundle: nil)
        let label = UILabel(); label.text = message; label.textAlignment = .center; label.backgroundColor = paper; view = label
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func textViewDidChangeSelection(_ textView: UITextView) {
        let selection = textView.selectedRange
        let start = min(NSMaxRange(range), max(range.location, selection.location))
        let end = min(NSMaxRange(range), max(start, NSMaxRange(selection)))
        let clamped = NSRange(location: start, length: end - start)
        if selection != clamped { textView.selectedRange = clamped }
    }
    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        let selection = NSIntersectionRange(self.range, range)
        guard selection.length > 0 else { return nil }
        return UIMenu(children: suggestedActions + [UIAction(title: "批注", image: UIImage(systemName: "pencil")) { [weak self] _ in self?.onSelection?(selection) }])
    }
}
