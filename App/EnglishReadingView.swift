import SwiftUI
import UIKit
import MoReadCore

struct EnglishReadingView: View {
    @Binding var value: ReaderTypography
    var body: some View {
        Form {
            Section("英文阅读") {
                Toggle("英文生词标注", isOn: Binding(get: { value.englishLearning ?? false }, set: { value.englishLearning = $0 })).accessibilityIdentifier("english-learning")
                Picker("标注方式", selection: Binding(get: { value.wordAnnotationMode ?? .inline }, set: { value.wordAnnotationMode = $0 })) {
                    ForEach(WordAnnotationMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }.accessibilityIdentifier("english-annotation-mode")
                Text("标注生词本中未掌握的英文词。划线标注可点按查看释义，直接显示使用已保存的简短释义与读音。").font(.caption).foregroundStyle(.secondary)
                Toggle("英文词首加粗", isOn: Binding(get: { value.englishBionic ?? false }, set: { value.englishBionic = $0 })).accessibilityIdentifier("english-bionic")
                Text("加粗每个英文单词的前半部分。").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                NavigationLink("查字词") { DictionaryLookupView() }
                NavigationLink("生词本") { VocabularyView() }
            }
        }.navigationTitle("阅读辅助")
    }
}

extension TextReader {
    func applyEnglishReading(to value: NSMutableAttributedString) {
        guard typography.englishBionic == true || typography.englishLearning == true else { return }
        let mode = typography.englishLearning == true ? typography.wordAnnotationMode ?? .inline : .off
        var spacedParagraphs = Set<Int>()
        for run in EnglishReading.words(in: presentation.source) {
            if typography.englishBionic == true {
                for range in presentation.displayRanges(forSource: run.prefix) {
                    value.enumerateAttribute(.font, in: range) { current, range, _ in
                        let base = current as? UIFont ?? font
                        let bold = UIFont(descriptor: base.fontDescriptor.withSymbolicTraits(base.fontDescriptor.symbolicTraits.union(.traitBold)) ?? base.fontDescriptor, size: base.pointSize)
                        value.addAttribute(.font, value: bold, range: range)
                    }
                }
            }
            guard mode != .off, let gloss = wordGlosses[run.word] else { continue }
            for range in presentation.displayRanges(forSource: run.range) {
                if mode == .popup {
                    value.addAttributes([.textItemTag: "moread-vocabulary", .underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: UIColor.systemTeal], range: range)
                } else if !gloss.meaning.isEmpty {
                    value.addAttribute(AnnotationLayoutManager.glossKey, value: [gloss.meaning, gloss.phonetic], range: range)
                    let paragraphRange = (value.string as NSString).paragraphRange(for: range)
                    if spacedParagraphs.insert(paragraphRange.location).inserted,
                       let style = (value.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
                        style.minimumLineHeight = font.lineHeight + fontSize * 1.2
                        value.addAttributes([.paragraphStyle: style, .baselineOffset: fontSize * 0.6], range: paragraphRange)
                    }
                }
            }
        }
    }
}

extension AnnotationLayoutManager {
    static let glossKey = NSAttributedString.Key("MoReadWordGloss")
    func drawWordGlosses(for glyphs: NSRange, at origin: CGPoint) {
        guard let storage = textStorage else { return }
        enumerateLineFragments(forGlyphRange: glyphs) { line, _, container, lineGlyphs, _ in
            let characters = self.characterRange(forGlyphRange: lineGlyphs, actualGlyphRange: nil)
            var labels: [(range: NSRange, bounds: CGRect, text: [String])] = []
            storage.enumerateAttribute(Self.glossKey, in: characters) { value, range, _ in
                guard let text = value as? [String], text.count == 2 else { return }
                let glyphRange = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                labels.append((range, self.boundingRect(forGlyphRange: glyphRange, in: container), text))
            }
            for (index, item) in labels.enumerated() {
                guard let font = storage.attribute(.font, at: item.range.location, effectiveRange: nil) as? UIFont else { continue }
                let center = item.bounds.midX
                let left = index == 0 ? container.lineFragmentPadding : (labels[index - 1].bounds.maxX + item.bounds.minX) / 2 + 2
                let right = index + 1 == labels.count ? container.size.width - container.lineFragmentPadding : (item.bounds.maxX + labels[index + 1].bounds.minX) / 2 - 2
                let width = max(item.bounds.width, 2 * min(center - left, right - center))
                let small = UIFont.systemFont(ofSize: font.pointSize * 0.46)
                let style = NSMutableParagraphStyle(); style.alignment = .center; style.lineBreakMode = .byTruncatingTail
                let attributes: [NSAttributedString.Key: Any] = [.font: small, .foregroundColor: ((storage.attribute(ReaderSyntaxPaint.key, at: item.range.location, effectiveRange: nil) as? ReaderSyntaxPaint)?.ink ?? storage.attribute(.foregroundColor, at: item.range.location, effectiveRange: nil) as? UIColor ?? .label).withAlphaComponent(0.75), .paragraphStyle: style]
                for (row, text) in item.text.enumerated() where !text.isEmpty {
                    let y = line.maxY - font.pointSize * (row == 0 ? 1.12 : 0.58)
                    (text as NSString).draw(with: CGRect(x: center - width / 2 + origin.x, y: y + origin.y, width: width, height: small.lineHeight), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes, context: nil)
                }
            }
        }
    }
}

extension UITextView {
    func vocabularyRange(at index: Int) -> NSRange? {
        guard index >= 0, index < textStorage.length else { return nil }
        var range = NSRange()
        // A tagged word can contain multiple font runs when its prefix is bold.
        let tag = textStorage.attribute(.textItemTag, at: index, longestEffectiveRange: &range, in: NSRange(location: 0, length: textStorage.length))
        return tag as? String == "moread-vocabulary" ? range : nil
    }
    func hasReadingAction(at point: CGPoint) -> Bool {
        let position = CGPoint(x: point.x - textContainerInset.left, y: point.y - textContainerInset.top)
        let glyph = layoutManager.glyphIndex(for: position, in: textContainer)
        guard glyph < layoutManager.numberOfGlyphs,
              layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer).contains(position) else { return false }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        let tag = textStorage.attribute(.textItemTag, at: index, effectiveRange: nil) as? String ?? ""
        return vocabularyRange(at: index) != nil || !AnnotationHit.ids(from: tag).isEmpty
    }
}
