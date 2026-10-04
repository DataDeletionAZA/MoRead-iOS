import UIKit
import MoReadCore

struct ReviewCardOptions: Equatable {
    var thought = true
    var book = true
    var date = true
    var watermark = true
}

enum ReviewCardRenderer {
    static func image(entry: ReadingReviewEntry, template: ReviewCardTemplate, options: ReviewCardOptions,
                      font: UIFont?, background: UIImage?, cover: Bool) throws -> UIImage {
        try template.validate()
        let width: CGFloat = 1080, gutter = CGFloat(template.padding), textWidth = width - gutter * 2
        func color(_ rgb: Int) -> UIColor { UIColor(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1) }
        let foreground = color(template.foreground), accent = color(template.accent)
        var quoteFont = font ?? UIFont.systemFont(ofSize: template.fontSize)
        if font == nil {
            let design: UIFontDescriptor.SystemDesign = template.font == .serif ? .serif : template.font == .monospace ? .monospaced : .default
            quoteFont = UIFont(descriptor: quoteFont.fontDescriptor.withDesign(design) ?? quoteFont.fontDescriptor, size: template.fontSize)
        }
        var traits = quoteFont.fontDescriptor.symbolicTraits
        if template.bold { traits.insert(.traitBold) }; if template.italic { traits.insert(.traitItalic) }
        quoteFont = UIFont(descriptor: quoteFont.fontDescriptor.withSymbolicTraits(traits) ?? quoteFont.fontDescriptor, size: template.fontSize)
        func block(_ text: String, font: UIFont, styled: Bool = false) -> NSAttributedString {
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping
            paragraph.lineSpacing = font.pointSize * (template.lineHeight - 1)
            if styled { paragraph.alignment = template.alignment == "center" ? .center : template.alignment == "right" ? .right : .left }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: foreground, .paragraphStyle: paragraph]
            if styled {
                attributes[.kern] = template.letterSpacing * font.pointSize
                if template.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                if template.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            return NSAttributedString(string: text, attributes: attributes)
        }
        let quote = block(entry.quote.isEmpty ? entry.title : entry.quote, font: quoteFont, styled: true)
        let plain = (try? AttributedString(markdown: entry.body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))).map { String($0.characters) } ?? entry.body
        let thought = options.thought && !plain.isEmpty ? block(plain, font: .systemFont(ofSize: 32)) : nil
        var metadata: [String] = []
        if options.book {
            metadata.append(entry.book.title)
            if let passage = entry.passage, let chapter = entry.book.chapters.first(where: { $0.id == passage.chapter }) { metadata.append(chapter.title) }
            if case .note(let note) = entry.content, let from = note.fromChapter, let to = note.toChapter { metadata.append("第 \(from)–\(to) 章") }
        }
        if entry.characterID != nil { metadata.append(entry.author) }
        if options.date { let formatter = DateFormatter(); formatter.dateFormat = "yyyy.MM.dd"; metadata.append(formatter.string(from: entry.date)) }
        let footer = block(metadata.joined(separator: " · "), font: .systemFont(ofSize: 26))
        func height(_ value: NSAttributedString) -> CGFloat {
            guard value.length > 0 else { return 0 }
            return ceil(value.boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height)
        }
        let quoteHeight = height(quote), thoughtHeight = thought.map(height) ?? 0, footerHeight = height(footer)
        let footerBottom: CGFloat = options.watermark ? 144 : 80
        let contentHeight = 216 + quoteHeight + (thought == nil ? 0 : 100 + thoughtHeight) + 96 + footerHeight + footerBottom
        guard contentHeight.isFinite, contentHeight <= 8192 else { throw MoReadError.invalid("这条内容较长，请使用文字分享以保留全文。") }
        let cardHeight = max(920, ceil(contentHeight)), bounds = CGRect(x: 0, y: 0, width: width, height: cardHeight)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        return UIGraphicsImageRenderer(size: bounds.size, format: format).image { renderer in
            let context = renderer.cgContext
            UIBezierPath(roundedRect: bounds, cornerRadius: template.cornerRadius).addClip()
            color(template.background).setFill(); context.fill(bounds)
            if let end = template.gradientEnd, let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [color(template.background).cgColor, color(end).cgColor] as CFArray, locations: [0, 1]) {
                context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: cardHeight), options: [])
            }
            if let background, background.size.width > 0, background.size.height > 0 {
                let scale = max(width / background.size.width, cardHeight / background.size.height)
                let size = CGSize(width: background.size.width * scale, height: background.size.height * scale)
                background.draw(in: CGRect(x: (width - size.width) / 2, y: (cardHeight - size.height) / 2, width: size.width, height: size.height))
                if cover { UIColor(white: 0, alpha: 0.68).setFill(); context.fill(bounds) }
            }
            let breathingRoom = (cardHeight - contentHeight) * 0.42
            ("“" as NSString).draw(at: CGPoint(x: gutter - 8, y: 32 + breathingRoom), withAttributes: [.font: UIFont.systemFont(ofSize: 150), .foregroundColor: accent])
            var y = 216 + breathingRoom
            quote.draw(with: CGRect(x: gutter, y: y, width: textWidth, height: quoteHeight), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            y += quoteHeight
            if let thought {
                y += 60; accent.setStroke(); context.setLineWidth(3); context.move(to: CGPoint(x: gutter, y: y)); context.addLine(to: CGPoint(x: gutter + 80, y: y)); context.strokePath()
                y += 40; thought.draw(with: CGRect(x: gutter, y: y, width: textWidth, height: thoughtHeight), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            }
            footer.draw(with: CGRect(x: gutter, y: cardHeight - footerHeight - footerBottom, width: textWidth, height: footerHeight), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            if options.watermark { ("墨知 MoRead" as NSString).draw(at: CGPoint(x: gutter, y: cardHeight - 88), withAttributes: [.font: UIFont.systemFont(ofSize: 24), .foregroundColor: accent]) }
            if template.borderWidth > 0 {
                let border = UIBezierPath(roundedRect: bounds.insetBy(dx: template.borderWidth / 2, dy: template.borderWidth / 2), cornerRadius: max(0, template.cornerRadius - template.borderWidth / 2))
                border.lineWidth = template.borderWidth; accent.setStroke(); border.stroke()
            }
        }
    }
}
