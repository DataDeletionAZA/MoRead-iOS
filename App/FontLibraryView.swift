import SwiftUI
import UniformTypeIdentifiers
import MoReadCore

struct FontLibraryView: View {
    @EnvironmentObject private var model: LibraryModel
    @AppStorage("reader.typography") private var typographyData = Data()
    @State private var picker = false
    @State private var renaming: ImportedFont?
    @State private var removing: ImportedFont?
    @State private var name = ""
    private var selected: UUID? { ReaderTypography(data: typographyData).customFontID }
    var body: some View {
        List {
            Section {
                Button("导入字体", systemImage: "plus") { picker = true }.accessibilityIdentifier("import-font")
                if model.importing { ProgressView("正在导入…") }
                if selected != nil { Button("正文恢复内置字体") { select(nil) } }
            } footer: { Text("支持 TTF、OTF、TTC，每个文件最多 64 MB。导入后设为正文字体；EPUB 需关闭“保留原书排版”。") }
            ForEach(model.fonts) { font in
                Section {
                    HStack {
                        Text(font.name).font(.headline)
                        Spacer()
                        if selected == font.id { Image(systemName: "checkmark.circle.fill").accessibilityLabel("正文使用中") }
                    }
                    Text("墨知 MoRead · 阅读让世界更辽阔 Aa 123")
                        .font(model.customFont(font.id, size: 21).map(Font.init) ?? .body)
                        .accessibilityIdentifier("font-preview-" + font.id.uuidString)
                    Text(font.originalName).font(.caption).foregroundStyle(.secondary)
                    Button("设为正文") { select(font.id) }.disabled(selected == font.id)
                    Button("重命名") { name = font.name; renaming = font }
                    Button("删除字体", role: .destructive) { removing = font }
                }
            }
        }.navigationTitle("字体库").disabled(model.importing || model.maintenance)
            .fileImporter(isPresented: $picker, allowedContentTypes: FontLibrary.extensions.compactMap { UTType(filenameExtension: $0) }, allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): Task { await model.importFonts(urls) }
                case .failure(let error): model.error = error.localizedDescription
                }
            }
            .alert("重命名字体", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("字体名称", text: $name).accessibilityIdentifier("font-name")
                Button("取消", role: .cancel) { renaming = nil }
                Button("保存") {
                    if let font = renaming { model.perform { try model.fontLibrary?.rename(font, to: name); try model.reloadFonts() } }
                    renaming = nil
                }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .confirmationDialog("删除字体？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible, presenting: removing) { font in
                Button("删除字体", role: .destructive) {
                        model.perform {
                            try model.fontLibrary?.remove(font)
                            if selected == font.id { select(nil) }
                            try model.reloadFonts()
                        }
                    removing = nil
                }
            } message: { font in Text("删除“\(font.name)”后，使用它的正文会恢复内置字体。") }
    }
    private func select(_ id: UUID?) {
        var value = ReaderTypography(data: typographyData); value.customFontID = id; typographyData = value.encoded()
    }
}
