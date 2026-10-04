import SwiftUI
import UIKit

struct ReadingReviewText: View {
    var quote = ""
    let bodyText: String
    @ScaledMetric(relativeTo: .body) private var pointSize = 17.0
    @State private var rendered: Rendered?
    private struct Request: Equatable {
        let quote: String
        let body: String
        let size: CGFloat
    }
    private struct Rendered { let request: Request; let text: NSAttributedString }
    private var request: Request {
        .init(quote: quote, body: bodyText, size: pointSize)
    }
    var body: some View {
        Group {
            if let rendered, rendered.request == request { NativeReviewText(text: rendered.text) }
            else { ProgressView("正在排版…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.task(id: request) {
            let current = request
            do {
                let parsed = try await Self.parse(current.body)
                try Task.checkCancellation(); rendered = .init(request: current, text: Self.style(parsed, request: current))
            } catch {}
        }
    }
    private static func parse(_ text: String) async throws -> AttributedString {
        let work = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let parsed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
            try Task.checkCancellation()
            return parsed
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
    private static func style(_ parsed: AttributedString, request: Request) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 5
        let base: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: request.size), .foregroundColor: UIColor.label, .paragraphStyle: paragraph]
        let result = NSMutableAttributedString(string: "")
        if !request.quote.isEmpty {
            var attributes = base; attributes[.backgroundColor] = UIColor.quaternarySystemFill
            result.append(NSAttributedString(string: request.quote + (request.body.isEmpty ? "" : "\n\n"), attributes: attributes))
        }
        for run in parsed.runs {
            var attributes = base
            let intent = run.inlinePresentationIntent ?? []
            var font = intent.contains(.code) ? UIFont.monospacedSystemFont(ofSize: request.size, weight: .regular) : UIFont.systemFont(ofSize: request.size)
            var traits = font.fontDescriptor.symbolicTraits
            if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
            if intent.contains(.emphasized) { traits.insert(.traitItalic) }
            font = UIFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits) ?? font.fontDescriptor, size: request.size)
            attributes[.font] = font
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attributes[.link] = link }
            result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return result
    }
}

private struct NativeReviewText: UIViewRepresentable {
    let text: NSAttributedString
    final class Coordinator { var text: NSAttributedString? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false; view.isSelectable = true; view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.accessibilityIdentifier = "reading-review-body"
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        guard context.coordinator.text !== text else { return }
        context.coordinator.text = text; view.attributedText = text
        view.setContentOffset(.zero, animated: false)
    }
}
