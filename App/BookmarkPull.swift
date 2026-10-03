import UIKit

@MainActor
final class BookmarkPull: NSObject, UIGestureRecognizerDelegate {
    private weak var host: UIView?
    private let canStart: () -> Bool
    private let save: () async -> String
    private let pan = UIPanGestureRecognizer()
    private let banner = UIStackView()
    private let label = UILabel()
    private let icon = UIImageView()
    private var began = 0.0
    private var ready = false
    private var cancelled = false
    private var task: Task<Void, Never>?

    init(in view: UIView, canStart: @escaping () -> Bool, save: @escaping () async -> String) {
        host = view; self.canStart = canStart; self.save = save
        super.init()
        pan.maximumNumberOfTouches = 1; pan.delegate = self
        pan.addTarget(self, action: #selector(pulled(_:))); view.addGestureRecognizer(pan)
        label.font = .preferredFont(forTextStyle: .callout); label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0; label.accessibilityIdentifier = "bookmark-pull-status"
        icon.contentMode = .scaleAspectFit
        banner.axis = .horizontal; banner.spacing = 8
        banner.addArrangedSubview(icon); banner.addArrangedSubview(label)
        banner.isLayoutMarginsRelativeArrangement = true
        banner.layoutMargins = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        banner.backgroundColor = .secondarySystemBackground; banner.layer.cornerRadius = 12
        banner.isUserInteractionEnabled = false; banner.isHidden = true
        banner.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            banner.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            banner.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            icon.widthAnchor.constraint(equalToConstant: 22)
        ])
    }
    func cancel() {
        task?.cancel(); task = nil; cancelled = true; banner.isHidden = true
        pan.isEnabled = false; pan.isEnabled = true
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool { canStart() }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let movement = pan.velocity(in: host)
        return canStart() && movement.y > 0 && movement.y >= abs(movement.x) * 2
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        other is UIPanGestureRecognizer
    }
    private func show(_ text: String, filled: Bool) {
        label.text = text; icon.image = UIImage(systemName: filled ? "bookmark.fill" : "bookmark")
        banner.isHidden = false; host?.bringSubviewToFront(banner)
    }
    private func update() {
        guard !cancelled else { return }
        let movement = pan.translation(in: host)
        if abs(movement.x) > 10, abs(movement.x) > max(0, movement.y) * 1.5 {
            cancelled = true; banner.isHidden = true; return
        }
        let next = movement.y >= 144 && CACurrentMediaTime() - began >= 0.22
        if next && !ready {
            UISelectionFeedbackGenerator().selectionChanged()
            UIAccessibility.post(notification: .announcement, argument: "松开添加书签")
        }
        ready = next; show(ready ? "松开添加书签" : "下拉添加书签", filled: ready)
    }
    @objc private func pulled(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            task?.cancel(); began = CACurrentMediaTime(); ready = false; cancelled = false; update()
            task = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(220)) } catch { return }
                guard let self, pan.state == .began || pan.state == .changed else { return }
                update()
            }
        case .changed: update()
        case .ended:
            task?.cancel(); update()
            guard !cancelled, ready, canStart() else { banner.isHidden = true; return }
            task = Task { [weak self] in
                guard let self, canStart(), !Task.isCancelled else { return }
                let message = await save()
                guard !Task.isCancelled else { return }
                show(message, filled: true); UIAccessibility.post(notification: .announcement, argument: message)
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                banner.isHidden = true
            }
        case .cancelled, .failed:
            task?.cancel(); banner.isHidden = true
        default: break
        }
    }
}
