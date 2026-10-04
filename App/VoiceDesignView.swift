import SwiftUI
import AVFoundation
import MoReadCore

struct VoiceDesignView: View {
    @StateObject private var model: VoiceDesignModel
    private enum Input: Hashable { case name, description, language, request }
    @FocusState private var input: Input?
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var speech: SpeechPlayer
    @EnvironmentObject private var companion: CompanionModel
    @State private var request = ""
    @State private var reference: UUID?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    init(settings: CloudSpeechSettings, root: URL) {
        _model = StateObject(wrappedValue: VoiceDesignModel(settings: settings, root: root))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("AI 音色助手") {
                    ModelAssignmentPicker(task: .chat, title: "主对话模型").disabled(model.busy || model.saved)
                    Picker("参考角色", selection: $reference) {
                        Text("不指定").tag(UUID?.none)
                        ForEach(companion.characters) { Text($0.name).tag(Optional($0.id)) }
                    }.disabled(model.busy || model.saved).accessibilityIdentifier("design-reference")
                    ForEach(model.chats) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.role == "user" ? "你" : "音色助手").font(.caption).foregroundStyle(.secondary)
                            Text(entry.content).textSelection(.enabled)
                        }.accessibilityIdentifier(entry.role == "assistant" ? "design-assistant-reply" : "design-user-request")
                    }
                    TextField("描述想要的声音，或告诉助手如何调整", text: $request, axis: .vertical)
                        .lineLimit(2...5).focused($input, equals: .request).disabled(model.busy || model.saved).accessibilityIdentifier("design-ai-request")
                    Button("发送给音色助手") {
                        input = nil; speech.pause(); speech.stopPreview()
                        if model.send(request, provider: companion.settings.resolvedProvider(for: .chat), personas: companion.characters.map(VoiceDesignPersona.init), reference: reference) { request = "" }
                    }.disabled(model.busy || model.saved || request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("design-ai-send")
                    Text("助手可参考角色介绍、性格和对话示例，调整设定并生成试听。满意后再点击入库。").font(.caption).foregroundStyle(.secondary)
                }
                Section("声音设定") {
                    TextField("音色名称", text: $model.specification.name).focused($input, equals: .name).accessibilityIdentifier("design-name")
                    TextField("描述年龄感、音高、音色、口音与表达方式", text: $model.specification.description, axis: .vertical)
                        .lineLimit(4...10).focused($input, equals: .description).accessibilityIdentifier("design-description")
                    Picker("声音类型", selection: $model.specification.gender) {
                        Text("女声").tag("female"); Text("男声").tag("male"); Text("中性").tag("neutral")
                    }
                    TextField("语言代码，如 zh-CN", text: $model.specification.language)
                        .focused($input, equals: .language).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("design-language")
                }.disabled(model.busy || model.saved)
                Section {
                    Button(model.candidate == nil ? "生成音色与试听" : "按当前设定重新生成") {
                        speech.pause(); speech.stopPreview(); model.generate()
                    }.disabled(model.busy || model.saved).accessibilityIdentifier("design-generate")
                    Text("通过已保存的 Gemini 服务创建音色。生成会调用服务商；满意后点击入库，随后可在音色库选择为听书声音。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let candidate = model.candidate {
                    Section("试听候选") {
                        Text(candidate.id).font(.caption).textSelection(.enabled)
                        if !model.specification.matchesSound(candidate.specification) {
                            Text("声音设定已修改，请重新生成后再入库。").foregroundStyle(.orange).accessibilityIdentifier("design-changed")
                        }
                        if candidate.audio != nil {
                            Button(model.playing ? "停止试听" : "播放试听") { speech.pause(); speech.stopPreview(); model.togglePreview() }
                                .disabled(model.busy).accessibilityIdentifier("design-preview")
                        } else {
                            Button("重新获取试听") { model.fetchPreview() }.disabled(model.busy).accessibilityIdentifier("design-fetch")
                        }
                        Button(model.saved ? "已保存到音色库" : "满意，入库") { model.save() }
                            .disabled(!model.canSave || library.maintenance).accessibilityIdentifier("design-save")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if model.message != nil || model.busy {
                    HStack {
                        Text(model.message ?? "正在处理…").accessibilityIdentifier("design-status")
                        Spacer()
                        if model.busy { Button("停止") { model.stop() }.accessibilityIdentifier("design-stop") }
                    }.font(.callout).padding().background(.regularMaterial)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("声音设计")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer(); Button("收起键盘") { input = nil }.accessibilityIdentifier("design-keyboard-done")
                }
            }
            .onDisappear { model.close() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { model.stop() } }
            .onChange(of: speech.cloudSettings) { _, settings in if settings != model.settings { model.close(); dismiss() } }
            .onChange(of: reference) { _, id in
                if model.specification.name.isEmpty, let card = companion.characters.first(where: { $0.id == id }) {
                    model.specification.name = String((card.name + " 的声音").prefix(80))
                }
            }
            .onChange(of: companion.settings.resolvedProvider(for: .chat)) { _, _ in model.stop() }
            .onChange(of: companion.characters.map(VoiceDesignPersona.init)) { _, _ in model.stop() }
            .onChange(of: library.maintenance) { _, busy in if busy { model.close(); dismiss() } }
        }
    }
}

@MainActor private final class VoiceDesignModel: ObservableObject {
    struct Candidate {
        let id: String
        let specification: VoiceDesignSpecification
        var audio: Data?
    }
    @Published var chats: [ChatMessage] = []
    @Published var specification = VoiceDesignSpecification()
    @Published var candidate: Candidate?
    @Published var busy = false
    @Published var playing = false
    @Published var saved = false
    @Published var message: String?
    let settings: CloudSpeechSettings
    private let root: URL
    private var key: String?
    private var owned: Set<String> = []
    private var generation = UUID()
    private var closed = false
    private var task: Task<Void, Never>?
    private var playback: Task<Void, Never>?
    private var player: AVAudioPlayer?
    init(settings: CloudSpeechSettings, root: URL) { self.settings = settings; self.root = root }
    var canSave: Bool {
        !closed && !busy && !saved && candidate?.audio != nil && candidate.map { specification.matchesSound($0.specification) } == true && (try? specification.normalized()) != nil
    }
    private func credential() async throws -> String {
        if let key { return key }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--simulate-voice-design") { key = "voice-design-fixture"; return key! }
        #endif
        let value = try await KeychainStore.readAsync(settings.id); key = value; return value
    }
    private func perform(_ action: @escaping (UUID) async throws -> Void) {
        guard !closed, !busy, !saved else { return }
        stopPreview(); generation = UUID(); let token = generation; busy = true; message = nil
        task = Task {
            do { try await action(token) }
            catch is CancellationError {} catch { if generation == token && !closed { message = error.localizedDescription } }
            if generation == token { busy = false; task = nil }
        }
    }
    func generate() { perform { [self] token in try await generateCandidate(token) } }
    private func generateCandidate(_ token: UUID) async throws {
        try Task.checkCancellation()
        guard token == generation, !closed else { throw CancellationError() }
        let spec = try specification.normalized()
        let request = try GeminiVoiceDesign.createRequest(settings: settings, key: await credential(), specification: spec)
        message = "正在生成音色…"
        let result = try GeminiVoiceDesign.created(await fetch(request))
        // Never take cleanup ownership of a voice already present in the library.
        guard try !VoiceLibrary(root: root).voices().contains(where: { $0.providerHint == "GEMINI" && $0.voiceId.lowercased() == result.id.lowercased() }) else {
            throw MoReadError.invalid("服务返回的音色已经在音色库中，已保留原有音色。")
        }
        owned.insert(result.id)
        guard token == generation, !closed, !Task.isCancelled else { cleanLater(result.id); throw CancellationError() }
        let previous = candidate
        candidate = Candidate(id: result.id, specification: spec, audio: result.preview)
        if let previous, previous.id != result.id { cleanLater(previous.id) }
        message = result.preview == nil ? "音色已生成；可以重新获取试听，无需再次生成。" : "音色已生成，听听是否满意。"
    }
    func fetchPreview() { perform { [self] token in try await fetchCandidatePreview(token) } }
    private func fetchCandidatePreview(_ token: UUID) async throws {
        try Task.checkCancellation()
        guard token == generation, !closed else { throw CancellationError() }
        guard let current = candidate, owned.contains(current.id) else { throw MoReadError.invalid("请先生成一个音色。") }
        message = "正在获取试听…"
        let request = try GeminiVoiceDesign.voiceRequest(settings: settings, key: await credential(), id: current.id)
        let audio = try GeminiVoiceDesign.preview(await fetch(request), id: current.id)
        try Task.checkCancellation()
        guard token == generation, !closed, candidate?.id == current.id else { throw CancellationError() }
        candidate?.audio = audio; message = "试听已就绪。"
    }
    private func snapshot(reference: UUID?) throws -> String {
        var value: [String: Any] = ["name": specification.name, "description": specification.description, "gender": specification.gender, "language": specification.language, "saved": saved]
        if let reference { value["reference_persona_id"] = reference.uuidString }
        if let candidate {
            value["candidate_voice_id"] = candidate.id; value["preview_ready"] = candidate.audio != nil
            value["description_changed_after_generation"] = !specification.matchesSound(candidate.specification)
            value["generated_description"] = candidate.specification.description
        }
        return try VoiceDesignAssistant.json(value)
    }
    private func execute(_ action: VoiceDesignAction, token: UUID, personas: [VoiceDesignPersona], reference: UUID?) async throws -> String {
        try Task.checkCancellation(); guard token == generation, !closed, !saved else { throw CancellationError() }
        switch action {
        case .snapshot: break
        case .findPersonas(let query):
            let matches = personas.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }.prefix(30)
            return try VoiceDesignAssistant.json(["personas": matches.map { ["id": $0.id.uuidString, "name": $0.name, "description": String($0.description.prefix(160))] }])
        case .readPersona(let id):
            guard let card = personas.first(where: { $0.id == id }) else { throw MoReadError.invalid("角色不存在，请重新查找。") }; return try card.detail()
        case .update(let specification): self.specification = try specification.normalized()
        case .generate: try await generateCandidate(token)
        case .fetchPreview: try await fetchCandidatePreview(token)
        }
        return try snapshot(reference: reference)
    }
    func send(_ text: String, provider: AIProvider?, personas: [VoiceDesignPersona], reference: UUID?) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy, !saved, !closed else { return false }
        guard text.utf16.count <= 2000 else { message = "每次需求请控制在 2000 字以内。"; return false }
        if specification.name.isEmpty, let card = personas.first(where: { $0.id == reference }) { specification.name = String((card.name + " 的声音").prefix(80)) }
        let user = ChatMessage(role: "user", content: text), reply = ChatMessage(role: "assistant", content: "")
        chats = Array((chats + [user]).suffix(39)); let history = chats; chats.append(reply)
        perform { [self] token in
            message = "正在理解声音需求…"
            let stream: VoiceDesignAssistant.Stream
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--simulate-voice-assistant") {
                stream = Self.fixture(text: text, reference: reference)
            } else { stream = try await Self.stream(provider: provider) }
            #else
            stream = try await Self.stream(provider: provider)
            #endif
            try Task.checkCancellation()
            try await VoiceDesignAssistant.run(history: history, snapshot: snapshot(reference: reference), stream: stream,
                execute: { [self] action in try await execute(action, token: token, personas: personas, reference: reference) },
                onText: { [self] delta in await append(delta, id: reply.id, token: token) },
                onActivity: { [self] value in await activity(value, token: token) })
            if token == generation { message = "本轮处理完成，可试听或继续提出调整。" }
        }
        return true
    }
    private func append(_ text: String, id: UUID, token: UUID) {
        guard token == generation, !closed, let index = chats.firstIndex(where: { $0.id == id }) else { return }
        chats[index].content = String((chats[index].content + text).prefix(12000))
    }
    private func activity(_ value: String, token: UUID) { if token == generation && !closed { message = value } }
    private static func stream(provider: AIProvider?) async throws -> VoiceDesignAssistant.Stream {
        guard var provider else { throw MoReadError.invalid("请先选择助手模型，可在设置中添加 AI 服务商。") }
        let key = try await KeychainStore.readAsync(provider.id); provider.maxTokens = min(provider.maxTokens, 4000)
        let selected = provider
        return { messages, tools, exchanges, onText in
            try await ChatClient.turn(provider: selected, key: key, messages: messages, tools: tools, exchanges: exchanges, onDelta: onText)
        }
    }
    #if DEBUG
    private static func fixture(text: String, reference: UUID?) -> VoiceDesignAssistant.Stream {
        { _, _, exchanges, onText in
            try await Task.sleep(for: .milliseconds(text.contains("slow") ? 10_000 : 300))
            if text.contains("fail") { throw MoReadError.invalid("音色助手服务暂不可用") }
            var calls: [ChatToolCall] = []
            if exchanges.isEmpty {
                calls = [.init(id: "find", name: "find_voice_personas", arguments: "{}")]
                if let reference { calls.append(.init(id: "read", name: "read_voice_persona", arguments: try VoiceDesignAssistant.json(["persona_id": reference.uuidString]))) }
            } else if exchanges.count == 1 {
                calls = [.init(id: "set", name: "set_voice_design", arguments: try VoiceDesignAssistant.json(["name": "Assistant narrator", "description": text.contains("lower") ? "低沉温暖，吐字清晰" : "温暖沉稳，吐字清晰", "gender": "neutral", "language": "zh-CN"])), .init(id: "generate", name: "generate_voice_preview", arguments: "{}")]
            } else if exchanges.count == 2 {
                calls = [.init(id: "fetch", name: "fetch_voice_preview", arguments: "{}"), .init(id: "duplicate", name: "generate_voice_preview", arguments: "{}")]
            } else {
                guard exchanges.last?.results.last?.failed == true else { throw MoReadError.invalid("重复生成未被拦截") }
                let reply = "已按设定生成试听，请听听是否满意。"; await onText(reply)
                return .init(text: reply, calls: [], replay: Data("[]".utf8))
            }
            return .init(text: "", calls: calls, replay: Data("[]".utf8))
        }
    }
    #endif
    func save() {
        guard canSave, let candidate else { return }
        do {
            let spec = try specification.normalized()
            var voice = SavedVoice(voiceId: candidate.id, displayName: spec.name, providerHint: "GEMINI", tags: "Gemini,自定义," + spec.language, gender: spec.gender == "female" ? "FEMALE" : spec.gender == "male" ? "MALE" : "UNSPECIFIED")
            let endpoint = try GeminiVoiceDesign.voiceRequest(settings: settings, key: "metadata", id: candidate.id).url!.deletingLastPathComponent().deletingLastPathComponent().absoluteString
            let extra = try JSONSerialization.data(withJSONObject: ["voice_design": ["description": candidate.specification.description, "language": spec.language, "source_base_url": endpoint, "created_at": Int64(Date().timeIntervalSince1970 * 1000)]])
            voice.extraJson = String(decoding: extra, as: UTF8.self)
            try VoiceLibrary(root: root).merge([voice])
            owned.remove(candidate.id); saved = true; stopPreview(); message = "已保存到音色库。"
        } catch { message = error.localizedDescription }
    }
    func stop() {
        generation = UUID(); task?.cancel(); task = nil; busy = false; stopPreview()
        if !closed { message = "已停止，已完成的试听仍保留。" }
    }
    func close() {
        guard !closed else { return }; closed = true; stop()
        for id in owned { cleanLater(id) }
    }
    private func cleanLater(_ id: String) {
        Task { [self] in
            guard owned.contains(id), let key else { return }
            do {
                if try VoiceLibrary(root: root).voices().contains(where: { $0.providerHint == "GEMINI" && $0.voiceId.lowercased() == id.lowercased() }) { owned.remove(id); return }
                let request = try GeminiVoiceDesign.voiceRequest(settings: settings, key: key, id: id, deleting: true)
                _ = try await fetch(request); owned.remove(id)
            } catch { if !closed { message = "未保存的云端草稿清理未成功；退出时会再次尝试。" } }
        }
    }
    private func stopPreview() { playback?.cancel(); playback = nil; player?.stop(); player = nil; playing = false }
    func togglePreview() {
        if playing { stopPreview(); return }
        guard !busy, let data = candidate?.audio else { return }
        do {
            let audio = try AVAudioPlayer(data: data)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            guard audio.prepareToPlay(), audio.play() else { throw MoReadError.invalid("试听音频暂时无法播放。") }
            player = audio; playing = true
            playback = Task { [weak self] in
                do { while audio.isPlaying { try await Task.sleep(for: .milliseconds(200)) } } catch { return }
                self?.stopPreview()
            }
        } catch { message = error.localizedDescription }
    }
    private func fetch(_ request: URLRequest) async throws -> Data {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--simulate-voice-design") {
            let flags = ProcessInfo.processInfo.arguments
            try await Task.sleep(for: .milliseconds(flags.contains("--slow-voice-design") ? 10_000 : 300))
            if flags.contains("--failed-voice-design") { throw MoReadError.invalid("声音设计服务暂不可用") }
            let id = request.httpMethod == "POST" ? "voice_" + UUID().uuidString : request.url!.lastPathComponent
            if request.httpMethod == "DELETE" { return Data() }
            var value: [String: Any] = ["id": id]
            if request.httpMethod != "POST" || !flags.contains("--missing-design-preview") {
                let bytes = Data(repeating: 0, count: 24000 * 2 * 8)
                value["sample_audio"] = ["mime_type": "audio/pcm;rate=24000", "data": bytes.base64EncodedString()]
            }
            return try JSONSerialization.data(withJSONObject: value)
        }
        #endif
        return try await GeminiVoiceDesign.fetch(request)
    }
}
