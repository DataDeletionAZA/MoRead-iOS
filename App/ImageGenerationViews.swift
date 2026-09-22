import SwiftUI
import MoReadCore

struct ImageGenerationSettingsView: View {
    @EnvironmentObject private var companion: CompanionModel
    @State private var draft = ImageGenerationSettings()
    @State private var key = ""
    @State private var hasKey = false
    @State private var status: String?
    var body: some View {
        Form {
            Section {
                Picker("绘图接口", selection: Binding(get: { draft.service }, set: { draft.preset($0); key = ""; checkKey() })) {
                    ForEach(ImageGenerationService.allCases, id: \.self) { Text($0.label).tag($0) }
                }.accessibilityIdentifier("image-service")
                TextField("HTTPS 服务地址", text: $draft.baseURL).accessibilityIdentifier("image-base-url")
                TextField("模型名称", text: $draft.model).accessibilityIdentifier("image-model")
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
                Button("保存绘图设置") {
                    do {
                        _ = try ImageGenerationClient.request(settings: draft, key: "validation", prompt: "画面")
                        var settings = companion.settings; settings.imageGeneration = draft
                        try companion.saveModelSettings(settings); status = "绘图设置已保存。"
                    } catch { status = error.localizedDescription }
                }.accessibilityIdentifier("save-image-settings")
                if let status { Text(status).font(.caption).accessibilityIdentifier("image-settings-status") }
            } footer: { Text("在书籍的插图廊或选中文字段落后开始生成。开启整理时，先由主对话模型把描述转换为绘图提示词，NovelAI 使用英文画面标签。每次生成或重新生成会发送描述并按所用服务商规则计费。") }
            Section("当前接口的密钥") {
                Text(hasKey ? "已保存密钥" : "尚未保存密钥").font(.caption)
                SecureField("输入新的 API Key", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("保存密钥") { saveKey(key.trimmingCharacters(in: .whitespacesAndNewlines)) }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if hasKey { Button("删除密钥", role: .destructive) { saveKey("") } }
            }
        }.navigationTitle("AI 绘图")
            .onAppear {
                if let saved = companion.settings.imageGeneration { draft = saved } else { draft.preset(.images) }
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
    private var policy: ImageGenerationSettings { companion.settings.imageGeneration ?? ImageGenerationSettings() }
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
                Text(policy.configured ? policy.service.label + " · " + policy.model : "请先保存绘图设置与密钥。").font(.caption).foregroundStyle(.secondary)
                Button(latest == nil ? "生成插图" : "重新生成一张") { generate() }
                    .disabled(task != nil || !policy.configured || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || library.maintenance)
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
            .onChange(of: policy) { _, _ in stop() }
            .onChange(of: library.maintenance) { _, busy in if busy { stop() } }
    }
    private func stop() { requestID = nil; task?.cancel(); task = nil }
    private func generate() {
        guard task == nil, !library.maintenance, let store = library.store, let book = library.books.first(where: { $0.id == bookID && !$0.removed && $0.hasBody }) else { return }
        focused = false; library.flush()
        let policy = policy, prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines), id = UUID()
        let promptProvider = policy.optimizePrompt != false ? companion.settings.resolvedProvider(for: .chat) : nil
        requestID = id; status = nil
        task = Task {
            defer { if requestID == id { task = nil; requestID = nil } }
            do {
                if let source {
                    guard source.bookID == bookID, source.isValid(in: try store.chapter(source.chapter, in: book), scope: ReadingScope(through: book.readThrough)) else { throw MoReadError.invalid("选段不在当前已读范围，请重新选择。") }
                }
                let bytes: Data
                var imagePrompt = prompt
                @MainActor func validateCurrent() throws {
                    guard requestID == id, !library.maintenance, library.store === store, self.policy == policy,
                          policy.optimizePrompt == false || companion.settings.resolvedProvider(for: .chat) == promptProvider,
                          let current = library.books.first(where: { $0.id == bookID && !$0.removed }), current.chapters == book.chapters, current.readThrough >= book.readThrough else { throw MoReadError.invalid("书籍、已读范围或绘图设置已变化，请重新生成。") }
                }
                @MainActor func generateRemote() async throws -> Data {
                    status = "正在整理画面描述…"
                    let promptKey = try promptProvider.map { try KeychainStore.read($0.id) } ?? ""
                    imagePrompt = try await IllustrationPrompt.compose(prompt, service: policy.service, provider: promptProvider, key: promptKey)
                    try Task.checkCancellation(); try validateCurrent(); status = "正在生成插图…"
                    return try await ImageGenerationClient.generate(settings: policy, key: KeychainStore.read(policy.service.credentialID), prompt: imagePrompt)
                }
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--simulate-images") {
                    _ = try ImageGenerationClient.request(settings: policy, key: "fixture", prompt: prompt)
                    try await Task.sleep(for: .milliseconds(prompt.contains("slow") ? 5000 : 300))
                    if prompt.contains("fail") { throw MoReadError.invalid("本地绘图服务暂不可用。") }
                    guard let data = ReaderImage.coverFixture().pngData() else { throw MoReadError.invalid("无法读取测试图片。") }; bytes = data
                } else { bytes = try await generateRemote() }
                #else
                bytes = try await generateRemote()
                #endif
                try Task.checkCancellation()
                try validateCurrent()
                let image = try ReaderImage.thumbnail(bytes, maximum: 1600)
                let saved = try store.saveIllustration(data: bytes, bookID: bookID, prompt: imagePrompt, originalPrompt: prompt, model: policy.model, source: source, through: book.readThrough)
                latest = saved; preview = image; status = "已保存到插图廊。"
            } catch { if !Task.isCancelled, requestID == id { status = error.localizedDescription } }
        }
    }
}
