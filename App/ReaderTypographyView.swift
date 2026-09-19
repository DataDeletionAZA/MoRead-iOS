import SwiftUI
import UIKit
import MoReadCore

struct ReaderTypographyView: View {
    @Binding var value: ReaderTypography
    @EnvironmentObject private var model: LibraryModel
    let isEPUB: Bool
    var body: some View {
        Form {
            if isEPUB {
                Section {
                    Toggle("保留原书排版", isOn: $value.publisherStyles).accessibilityIdentifier("reader-publisher-styles")
                } footer: { Text("关闭后，下面的字体、段落设置会统一应用到可重排的 EPUB 正文。固定版式 EPUB 仍保持原页面。") }
            }
            Section("字体") {
                Picker("字体", selection: $value.font) {
                    ForEach(ReaderTypography.Font.allCases, id: \.self) { Text($0.label).tag($0) }
                }.accessibilityIdentifier("reader-font-family")
                    .onChange(of: value.font) { _, _ in value.customFontID = nil }
                if !model.fonts.isEmpty {
                    Picker("已导入字体", selection: $value.customFontID) {
                        Text("使用上面的字体").tag(UUID?.none)
                        ForEach(model.fonts) { Text($0.name).tag(Optional($0.id)) }
                    }.accessibilityIdentifier("reader-custom-font")
                }
                NavigationLink("管理与导入字体") { FontLibraryView() }
                Stepper("字重 \(value.weight)", value: $value.weight, in: 100...900, step: 100).accessibilityIdentifier("reader-font-weight").disabled(value.customFontID != nil)
                Text("雨后的书店 · MoRead 123").font(Font(model.customFont(value.customFontID, size: 21) ?? value.uiFont(size: 21))).accessibilityIdentifier("reader-font-preview")
            }.disabled(isEPUB && value.publisherStyles)
            Section("段落") {
                Stepper("字距 \(value.letterSpacing.formatted(.number.precision(.fractionLength(2)))) 字", value: $value.letterSpacing, in: 0...0.5, step: 0.05).accessibilityIdentifier("reader-letter-spacing")
                Stepper("段后距 \(Int(value.paragraphSpacing)) 点", value: $value.paragraphSpacing, in: 0...60, step: 2).accessibilityIdentifier("reader-paragraph-spacing")
                Stepper("首行缩进 \(value.firstLineIndent.formatted()) 字", value: $value.firstLineIndent, in: 0...4, step: 0.5).accessibilityIdentifier("reader-first-line-indent")
                Toggle("两端对齐", isOn: $value.justified).accessibilityIdentifier("reader-justified")
            }.disabled(isEPUB && value.publisherStyles)
            Section("页面留白") {
                if isEPUB {
                    Stepper("横向留白 \(value.epubPageMargins.formatted(.number.precision(.fractionLength(1)))) 倍", value: $value.epubPageMargins, in: 0...3, step: 0.2).accessibilityIdentifier("reader-epub-margins")
                } else {
                    Stepper("左侧 \(Int(value.marginLeft)) 点", value: $value.marginLeft, in: 0...64, step: 2).accessibilityIdentifier("reader-margin-left")
                    Stepper("右侧 \(Int(value.marginRight)) 点", value: $value.marginRight, in: 0...64, step: 2).accessibilityIdentifier("reader-margin-right")
                    Stepper("上方 \(Int(value.marginTop)) 点", value: $value.marginTop, in: 0...80, step: 2).accessibilityIdentifier("reader-margin-top")
                    Stepper("下方 \(Int(value.marginBottom)) 点", value: $value.marginBottom, in: 0...80, step: 2).accessibilityIdentifier("reader-margin-bottom")
                }
            }
            Section { Button("恢复默认字体与段落") { value = ReaderTypography() }.accessibilityIdentifier("reader-typography-reset") }
        }.navigationTitle("字体与段落")
    }
}

extension ReaderTypography {
    var insets: UIEdgeInsets { UIEdgeInsets(top: marginTop, left: marginLeft, bottom: marginBottom, right: marginRight) }
    func uiFont(size: CGFloat) -> UIFont {
        let weights: [UIFont.Weight] = [.ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black]
        if font == .serif {
            let styles = ["ExtraLight", "ExtraLight", "Light", "Regular", "Medium", "SemiBold", "Bold", "ExtraBold", "Black"]
            if let selected = UIFont(name: "NotoSerifSC-" + styles[min(8, max(0, weight / 100 - 1))], size: size) { return selected }
        }
        let base = UIFont.systemFont(ofSize: size, weight: weights[min(8, max(0, weight / 100 - 1))])
        let design: UIFontDescriptor.SystemDesign = font == .serif ? .serif : font == .monospace ? .monospaced : .default
        return base.fontDescriptor.withDesign(design).map { UIFont(descriptor: $0, size: size) } ?? base
    }
}
