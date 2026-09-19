import SwiftUI

extension Color {
    init(rgb: Int) {
        let value = (0...0xFFFFFF).contains(rgb) ? rgb : 0x476153
        self.init(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
    var savedRGB: Int {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return 0x476153 }
        func byte(_ value: CGFloat) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
        return byte(red) << 16 | byte(green) << 8 | byte(blue)
    }
}

struct ThemeView: View {
    @AppStorage("app.tintRGB") private var tint = 0x476153
    var body: some View {
        Form {
            ColorPicker("主题色", selection: Binding(get: { Color(rgb: tint) }, set: { tint = $0.savedRGB }), supportsOpacity: false)
            Section("预览") {
                Label("墨知 · 阅读与陪伴", systemImage: "book.closed").foregroundStyle(Color(rgb: tint))
            }
            Button("恢复默认主题色") { tint = 0x476153 }
        }.navigationTitle("主题与外观")
    }
}
