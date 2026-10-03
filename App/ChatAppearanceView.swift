import SwiftUI
import MoReadCore

struct ChatAppearanceView: View {
    @Binding var appearance: ChatAppearance
    var name: String
    @EnvironmentObject private var library: LibraryModel
    var body: some View {
        Form {
            Section("预览") {
                VStack(alignment: .leading, spacing: 16) {
                    Text(name + "：今天读到哪里了？")
                        .font(chatFont(appearance, library: library)).modifier(ChatBubble(appearance: appearance, fromUser: false))
                    Text("这一段很有意思，我们一起聊聊。")
                        .font(chatFont(appearance, library: library)).modifier(ChatBubble(appearance: appearance, fromUser: true))
                }.frame(maxWidth: .infinity).padding(16)
                    .background { ChatBackground(appearance: appearance) }.clipShape(RoundedRectangle(cornerRadius: 16))
                    .listRowInsets(EdgeInsets()).accessibilityIdentifier("chat-appearance-preview")
            }
            Section("气泡样式") {
                Picker("气泡样式", selection: $appearance.bubble) {
                    ForEach(ChatAppearance.Bubble.allCases, id: \.self) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("chat-bubble-style")
                ColorPicker("角色气泡颜色", selection: Binding(get: { appearance.assistantRGB.map(Color.init(rgb:)) ?? Color(uiColor: .secondarySystemBackground) }, set: { appearance.assistantRGB = $0.savedRGB }), supportsOpacity: false)
                ColorPicker("我的气泡颜色", selection: Binding(get: { appearance.userRGB.map(Color.init(rgb:)) ?? Color.accentColor }, set: { appearance.userRGB = $0.savedRGB }), supportsOpacity: false)
                if appearance.assistantRGB != nil || appearance.userRGB != nil {
                    Button("气泡颜色跟随主题") { appearance.assistantRGB = nil; appearance.userRGB = nil }
                }
            }
            Section("聊天背景") {
                NavigationLink(appearance.backgroundID.flatMap { id in library.images.first { $0.id == id }?.name } ?? "从图片库选择背景") {
                    ImageLibraryView(select: { appearance.backgroundID = $0.id })
                }.accessibilityIdentifier("chat-background-picker")
                if appearance.backgroundID != nil {
                    Button("不使用背景图") { appearance.backgroundID = nil }
                    Slider(value: $appearance.backgroundDim, in: 0...1) { Text("背景蒙版") }.accessibilityIdentifier("chat-background-dim")
                    Text("背景蒙版 \(Int((appearance.backgroundDim * 100).rounded()))% · 越高，背景越淡").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("聊天文字") {
                Picker("字体", selection: $appearance.fontID) {
                    Text("跟随应用").tag(nil as UUID?)
                    ForEach(library.fonts) { font in Text(font.name).tag(Optional(font.id)) }
                    if let id = appearance.fontID, !library.fonts.contains(where: { $0.id == id }) { Text("字体已移除 · 跟随应用").tag(Optional(id)) }
                }.accessibilityIdentifier("chat-font")
                NavigationLink("管理与导入字体") { FontLibraryView() }
                Slider(value: $appearance.fontScale, in: 0.8...1.6) { Text("字号") }.accessibilityIdentifier("chat-font-slider")
                Stepper("字号 \(Int((appearance.fontScale * 100).rounded()))%", value: $appearance.fontScale, in: 0.8...1.6, step: 0.1).accessibilityIdentifier("chat-font-scale")
            }
            if appearance != ChatAppearance() { Button("恢复默认外观") { appearance = ChatAppearance() }.accessibilityIdentifier("chat-appearance-reset") }
        }.navigationTitle("聊天外观")
    }
}

@MainActor
func chatFont(_ appearance: ChatAppearance, library: LibraryModel, size: CGFloat = 17, style: UIFont.TextStyle = .body) -> Font {
    let font = library.customFont(appearance.fontID, size: size * appearance.fontScale) ?? UIFont.systemFont(ofSize: size * appearance.fontScale)
    return Font(UIFontMetrics(forTextStyle: style).scaledFont(for: font))
}

struct ChatBackground: View {
    var appearance: ChatAppearance
    @EnvironmentObject private var library: LibraryModel
    var body: some View {
        GeometryReader { proxy in
            Color(uiColor: .systemBackground)
            if let image = library.sharedImage(appearance.backgroundID) {
                Image(uiImage: image).resizable().scaledToFill().frame(width: proxy.size.width, height: proxy.size.height).clipped()
                Color(uiColor: .systemBackground).opacity(appearance.backgroundDim)
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct ChatBubble: ViewModifier {
    var appearance: ChatAppearance
    var fromUser: Bool
    var isTail = true
    @AppStorage("app.tintRGB") private var tint = 0x476153
    private var custom: Int? { fromUser ? appearance.userRGB : appearance.assistantRGB }
    private var base: Color { custom.map(Color.init(rgb:)) ?? (fromUser ? .accentColor : Color(uiColor: .secondarySystemBackground)) }
    private var foreground: Color {
        if appearance.bubble == .glass || appearance.bubble == .outlined { return .primary }
        if let custom = custom ?? (fromUser ? tint : nil) {
            return ChatAppearance.darkText(onRGB: custom) ? .black : .white
        }
        return fromUser ? .white : .primary
    }
    private var opacity: Double {
        switch appearance.bubble { case .rounded: return 1; case .outlined: return 0; case .paper: return 0.94; case .glass: return 0.34 }
    }
    private var radius: CGFloat {
        switch appearance.bubble { case .rounded: return 16; case .outlined: return 14; case .paper: return 6; case .glass: return 18 }
    }
    func body(content: Content) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: isTail && !fromUser ? 5 : radius, bottomTrailingRadius: isTail && fromUser ? 5 : radius, topTrailingRadius: radius)
        content.padding(16).foregroundStyle(foreground).tint(foreground)
            .background(base.opacity(opacity), in: shape)
            .overlay { if appearance.bubble == .outlined || appearance.bubble == .glass { shape.strokeBorder(base.opacity(appearance.bubble == .outlined ? 0.7 : 0.45), lineWidth: 1).allowsHitTesting(false) } }
    }
}
