import SwiftUI
import MoReadCore

struct ImageGenerationSettingsView: View {
    @EnvironmentObject private var companion: CompanionModel
    @State private var draft = ImageGenerationSettings()
    @State private var key = ""
    @State private var hasKey = false
    @State private var loaded = false
    @State private var status: String?
    var body: some View {
        Form {
            Section {
                Toggle("使用模型分工的绘图模型", isOn: Binding(get: { draft.useAssignedModel == true }, set: { draft.useAssignedModel = $0 }))
                    .accessibilityIdentifier("image-use-assigned")
                if draft.useAssignedModel == true {
                    ModelAssignmentPicker(task: .image)
                    NavigationLink("管理 AI 服务商") { AISettingsView() }
                }
                Picker("绘图接口", selection: Binding(get: { draft.service }, set: { draft.preset($0); key = ""; checkKey() })) {
                    ForEach(ImageGenerationService.allCases, id: \.self) { Text($0.label).tag($0) }
                }.accessibilityIdentifier("image-service")
                if draft.useAssignedModel != true {
                    TextField("HTTPS 服务地址", text: $draft.baseURL).accessibilityIdentifier("image-base-url")
                    TextField("模型名称", text: $draft.model).accessibilityIdentifier("image-model")
                }
                TextField("接口路径", text: $draft.endpoint)
                TextField("图片尺寸，例如 1024x1024", text: $draft.size)
            }.textInputAutocapitalization(.never).autocorrectionDisabled()
            if draft.service == .novelAI {
                Section("NovelAI") {
                    TextField("固定正向提示词", text: $draft.positivePrompt, axis: .vertical)
                    TextField("负面提示词", text: $draft.negativePrompt, axis: .vertical)
                    TextField("采样器", text: $draft.sampler).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Stepper("生成步数：\(draft.steps)", value: $draft.steps, in: 1...50)
                    Slider(value: $draft.scale, in: 0...10, step: 0.1) { Text("提示词强度") }
                    Text("提示词强度：\(draft.scale.formatted(.number.precision(.fractionLength(1))))")
                }
            }
            Section {
                Toggle("AI 整理画面描述", isOn: Binding(get: { draft.optimizePrompt != false }, set: { draft.optimizePrompt = $0 }))
                Toggle("允许伴读生成插图", isOn: Binding(get: { draft.companionEnabled == true }, set: { draft.companionEnabled = $0 })).accessibilityIdentifier("image-companion-enabled")
                Button("保存绘图设置") {
                    do {
                        var settings = companion.settings; settings.imageGeneration = draft
                        guard let connection = settings.imageConnection else { throw MoReadError.invalid("请先选择绘图模型，或填写独立绘图配置。") }
                        _ = try ImageGenerationClient.request(settings: connection.settings, key: "validation", prompt: "画面")
                        try companion.saveModelSettings(settings); status = "绘图设置已保存。"
                    } catch { status = error.localizedDescription }
                }.accessibilityIdentifier("save-image-settings")
                if let status { Text(status).font(.caption).accessibilityIdentifier("image-settings-status") }
            } footer: { Text("在书籍的插图廊或选中文字段落后开始生成。开启整理时，先由主对话模型把描述转换为绘图提示词，NovelAI 使用英文画面标签。每次生成或重新生成会发送描述并按所用服务商规则计费。允许伴读绘图后，角色可使用绘图工具，每条回复最多生成 4 张。") }
            if draft.useAssignedModel != true { Section("当前接口的密钥") {
                Text(hasKey ? "已保存密钥" : "尚未保存密钥").font(.caption)
                SecureField("输入新的 API Key", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("保存密钥") { saveKey(key.trimmingCharacters(in: .whitespacesAndNewlines)) }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if hasKey { Button("删除密钥", role: .destructive) { saveKey("") } }
            } }
        }.navigationTitle("AI 绘图")
            .onAppear {
                if !loaded {
                    if let saved = companion.settings.imageGeneration { draft = saved }
                    else { draft.preset(.images); draft.useAssignedModel = companion.settings.imageProvider != nil }
                    loaded = true
                }
                checkKey()
            }
    }
    private func checkKey() { do { hasKey = !(try KeychainStore.read(draft.service.credentialID)).isEmpty } catch { status = error.localizedDescription } }
    private func saveKey(_ value: String) {
        do { try KeychainStore.save(value, for: draft.service.credentialID); key = ""; checkKey(); status = value.isEmpty ? "密钥已删除。" : "密钥已保存。" }
        catch { status = error.localizedDescription }
    }
}

struct IllustrationGenerator: View {
    let bookID: UUID
    let source: SourcePassage?
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var companion: CompanionModel
    @State private var prompt: String
    @State private var latest: BookIllustration?
    @State private var preview: UIImage?
    @State private var status: String?
    @State private var task: Task<Void, Never>?
    @State private var requestID: UUID?
    @FocusState private var focused: Bool
    private var connection: ImageGenerationConnection? { companion.settings.imageConnection }
    init(bookID: UUID, source: SourcePassage? = nil, prompt: String? = nil) {
        self.bookID = bookID; self.source = source
        _prompt = State(initialValue: prompt ?? source.map { "小说插画，忠实表现以下选段，无文字、无水印：\n" + $0.text } ?? "")
    }
    var body: some View {
        Form {
            if let source { Section("原文") { Text(source.text).font(.callout).textSelection(.enabled) } }
            Section {
                TextEditor(text: $prompt).frame(minHeight: 120).focused($focused).accessibilityIdentifier("illustration-prompt").accessibilityLabel("画面描述")
                NavigationLink("绘图设置") { ImageGenerationSettingsView() }
                Text(connection?.label ?? "请先配置绘图模型与密钥。").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("illustration-model")
                Button(latest == nil ? "生成插图" : "重新生成一张") { generate() }
                    .disabled(task != nil || connection == nil || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || library.maintenance)
                    .accessibilityIdentifier("generate-illustration")
            } header: { Text("画面描述") } footer: { Text("这里的描述会发送给绘图服务；开启 AI 整理时，也会发送给主对话模型。生成后自动保存到这本书的插图廊；重新生成会保留之前的图片。") }
            if task != nil { Section { ProgressView("正在生成插图…"); Button("停止生成") { stop(); status = "已停止。" } } }
            if let status { Section { Text(status).font(.caption).accessibilityIdentifier("illustration-status") } }
            if let preview, let latest {
                Section("已保存的插图") {
                    Image(uiImage: preview).resizable().scaledToFit().frame(maxHeight: 350).accessibilityIdentifier("generated-illustration")
                    NavigationLink("查看与导出") { IllustrationDetail(item: latest) }
                }
            }
            NavigationLink("插图廊") { IllustrationGallery(bookID: bookID) }
        }.navigationTitle("生成插图")
            .onDisappear { stop() }
            .onChange(of: connection) { _, _ in stop() }
            .onChange(of: library.maintenance) { _, busy in if busy { stop() } }
    }
    private func stop() { if task != nil { status = "已停止。" }; requestID = nil; task?.cancel(); task = nil }
    private func generate() {
        guard task == nil, !library.maintenance, let connection, let book = library.books.first(where: { $0.id == bookID && !$0.removed && $0.hasBody }) else { return }
        focused = false; library.flush()
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines), id = UUID()
        let promptProvider = connection.settings.optimizePrompt != false ? companion.settings.resolvedProvider(for: .chat) : nil
        requestID = id; status = nil
        task = Task {
            defer { if requestID == id { task = nil; requestID = nil } }
            do {
                let result = try await library.generateIllustration(prompt: prompt, source: source, book: book, connection: connection, promptProvider: promptProvider, validate: {
                    guard requestID == id, self.connection == connection,
                          connection.settings.optimizePrompt == false || companion.settings.resolvedProvider(for: .chat) == promptProvider else { throw CancellationError() }
                }, progress: { status = $0 })
                latest = result.item; preview = try ReaderImage.thumbnail(result.data, maximum: 1600); status = "已保存到插图廊。"
            } catch { if !Task.isCancelled, requestID == id { status = error.localizedDescription } }
        }
    }
}

extension LibraryModel {
    func generateIllustration(prompt: String, source: SourcePassage?, book: Book, connection: ImageGenerationConnection, promptProvider: AIProvider?, anchor: ReadingPosition? = nil, character: CharacterCard? = nil,
                              validate: @MainActor () throws -> Void, progress: @MainActor (String) -> Void = { _ in }) async throws -> (item: BookIllustration, data: Data) {
        guard let storage = store else { throw MoReadError.invalid("书库尚未打开。") }
        @MainActor func check() throws {
            try Task.checkCancellation()
            guard !maintenance, store === storage else { throw CancellationError() }
            try ReaderTools.validate(book, current: books); try validate()
        }
        try check()
        guard (character?.name.utf16.count ?? 0) <= 512 else { throw MoReadError.invalid("插图作者名称过长。") }
        if let source {
            guard source.bookID == book.id, source.isValid(in: try storage.chapter(source.chapter, in: book), scope: ReadingScope(through: book.readThrough)) else { throw MoReadError.invalid("选段不在当前已读范围，请重新选择。") }
        }
        var imagePrompt = prompt
        @MainActor func remote() async throws -> Data {
            progress("正在整理画面描述…")
            let promptKey = try promptProvider.map { try KeychainStore.read($0.id) } ?? ""
            imagePrompt = try await IllustrationPrompt.compose(prompt, service: connection.settings.service, provider: promptProvider, key: promptKey)
            try check(); progress("正在生成插图…")
            return try await ImageGenerationClient.generate(settings: connection.settings, key: KeychainStore.read(connection.credentialID), prompt: imagePrompt)
        }
        let bytes: Data
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--simulate-images") {
            _ = try ImageGenerationClient.request(settings: connection.settings, key: "fixture", prompt: prompt)
            progress("正在生成插图…")
            try await Task.sleep(for: .milliseconds(prompt.contains("slow") ? 5000 : 300))
            if prompt.contains("fail") { throw MoReadError.invalid("本地绘图服务暂不可用。") }
            guard let data = ReaderImage.coverFixture().pngData() else { throw MoReadError.invalid("无法读取测试图片。") }; bytes = data
        } else { bytes = try await remote() }
        #else
        bytes = try await remote()
        #endif
        try check()
        let saved = try storage.saveIllustration(data: bytes, bookID: book.id, prompt: imagePrompt, originalPrompt: prompt, model: connection.settings.model, source: source, through: book.readThrough, anchor: anchor, characterID: character?.id, characterName: character?.name)
        recordsRevision = UUID()
        return (saved, bytes)
    }
}
