import SwiftUI
import UniformTypeIdentifiers
import PhotosUI
import ImageIO
import MoReadCore

struct ChatDestination: Identifiable { let id: UUID }

struct CompanionHome: View {
    @EnvironmentObject private var companion: CompanionModel
    @State private var chat: ChatDestination?
    @State private var cards = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { cards = true } label: {
                        HStack(spacing: 16) {
                            Image(systemName: "sparkles").font(.title2).frame(width: 48, height: 48).background(Color.accentColor.opacity(0.10), in: Circle())
                            VStack(alignment: .leading, spacing: 4) {
                                Text(companion.characters.first { $0.id == companion.settings.selectedCharacter }?.name ?? "选择共读伙伴").font(.headline)
                                Text("角色与世界书").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(); Image(systemName: "chevron.right").font(.caption)
                        }.padding(.vertical, 6)
                    }.foregroundStyle(.primary)
                    Button("开启新话题", systemImage: "square.and.pencil") {
                        if let id = companion.newConversation(book: nil) { chat = ChatDestination(id: id) }
                    }
                    NavigationLink("我的身份：\(companion.settings.currentIdentity.label)") { UserMaskSettingsView() }
                }
                Section("最近的对话") {
                    ForEach(companion.conversations.sorted { $0.updatedAt > $1.updatedAt }) { conversation in
                        Button { chat = ChatDestination(id: conversation.id) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(conversation.title).foregroundStyle(.primary)
                                Text(conversation.messages.last?.content ?? "说说你正在读的故事").lineLimit(2).font(.caption).foregroundStyle(.secondary)
                            }
                        }.swipeActions { Button("删除", role: .destructive) { companion.delete(conversation.id) }.disabled(companion.activeConversation == conversation.id) }
                    }
                }
            }.navigationTitle("伴读")
                .sheet(isPresented: $cards) { CharacterList() }
                .sheet(item: $chat) { target in NavigationStack { CompanionChat(conversationID: target.id) } }
        }
    }
}

struct CharacterList: View {
    @EnvironmentObject private var companion: CompanionModel
    @Environment(\.dismiss) private var dismiss
    @State private var picker = false
    @State private var editing: CharacterCard?
    var body: some View {
        NavigationStack {
            List(companion.characters) { card in
                HStack(spacing: 12) {
                    if let data = card.avatar, let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFill().frame(width: 48, height: 48).clipShape(Circle()) }
                    else { Image(systemName: "person.crop.circle").font(.largeTitle).foregroundStyle(.secondary) }
                    Button { companion.settings.selectedCharacter = card.id; companion.saveSettings() } label: {
                        VStack(alignment: .leading) { Text(card.name).foregroundStyle(.primary); Text("\(card.worldBook.count) 条世界书设定").font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if companion.settings.selectedCharacter == card.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                    Button("编辑", systemImage: "pencil") { editing = card }.labelStyle(.iconOnly).buttonStyle(.borderless)
                }
            }.navigationTitle("共读伙伴")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) { Menu("添加", systemImage: "plus") { Button("导入 PNG / JSON 角色卡") { picker = true }; Button("新建角色") { editing = CharacterCard(name: "新伙伴", description: "") } } }
                }
                .sheet(item: $editing) { card in CharacterEditor(card: card) }
                .fileImporter(isPresented: $picker, allowedContentTypes: [.json, .png]) { result in
                    companion.perform {
                        let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                        companion.saveCard(try CharacterCardImporter.parse(CharacterCardImporter.read(url)))
                    }
                }
        }
    }
}

struct CharacterEditor: View {
    @State var card: CharacterCard
    @State private var avatarSelection: PhotosPickerItem?
    @State private var imageError: String?
    @EnvironmentObject private var companion: CompanionModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let data = card.avatar, let image = UIImage(data: data) {
                        Image(uiImage: image).resizable().scaledToFill().frame(width: 88, height: 88).clipShape(Circle()).accessibilityLabel("角色头像")
                    }
                    PhotosPicker("更换头像", selection: $avatarSelection, matching: .images)
                    if card.avatar != nil { Button("移除头像", role: .destructive) { avatarSelection = nil; card.avatar = nil } }
                    TextField("名字", text: $card.name)
                    NavigationLink("世界书（\(card.worldBook.count) 条）") { WorldBookEditor(entries: $card.worldBook) }.accessibilityIdentifier("edit-world-book")
                    NavigationLink("角色记忆") { PersonaMemoryView(characterID: card.id) }
                    NavigationLink("可用工具") { CharacterToolsView(enabled: $card.enabledTools) }
                }
                Section("人物设定") { TextEditor(text: $card.description).frame(minHeight: 130) }
                Section("性格") { TextEditor(text: $card.personality).frame(minHeight: 80) }
                Section("场景") { TextEditor(text: $card.scenario).frame(minHeight: 80) }
                Section("开场白") { TextEditor(text: $card.greeting).frame(minHeight: 80) }
                Section("说话示例") { TextEditor(text: $card.exampleDialogue).frame(minHeight: 100) }

            }.navigationTitle("角色资料")
                .task(id: avatarSelection) {
                    guard let avatarSelection else { return }
                    do {
                        guard let data = try await avatarSelection.loadTransferable(type: Data.self),
                              let encoded = try ReaderImage.thumbnail(data, maximum: 512).pngData() else { throw MoReadError.invalid("无法读取头像。") }
                        try Task.checkCancellation(); card.avatar = encoded
                    } catch is CancellationError {} catch { imageError = error.localizedDescription }
                }
                .alert("头像未更换", isPresented: Binding(get: { imageError != nil }, set: { if !$0 { imageError = nil } })) { Button("好", role: .cancel) {} } message: { Text(imageError ?? "") }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") { companion.saveCard(card); if companion.error == nil { dismiss() } }.disabled(card.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                }
        }
    }
}

struct AISettingsView: View {
    @EnvironmentObject private var companion: CompanionModel
    @State private var editing: AIProvider?
    var body: some View {
        List {
            Section("你的称呼") { TextField("称呼", text: $companion.settings.userName).onSubmit { companion.saveSettings() } }
            Section("服务商") {
                ForEach(companion.settings.providers) { provider in
                    Button { editing = provider } label: {
                        HStack {
                            VStack(alignment: .leading) { Text(provider.name); Text(provider.model).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            if provider.id == companion.settings.selectedProvider { Image(systemName: "checkmark.circle.fill") }
                        }
                    }
                }
                Button("添加服务商", systemImage: "plus") { editing = AIProvider() }
            }
            Section { Text("使用你自己的服务商账号。密钥保存在这台设备的钥匙串中，书中选段和对话会在发送时交给你选择的服务商。").font(.footnote).foregroundStyle(.secondary) }
        }.navigationTitle("AI 服务商")
            .sheet(item: $editing) { provider in ProviderEditor(provider: provider) }
            .onDisappear { companion.saveSettings() }
    }
}

struct ProviderEditor: View {
    @State var provider: AIProvider
    @State private var key = ""
    @EnvironmentObject private var companion: CompanionModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                TextField("服务商名称", text: $provider.name)
                Picker("接口类型", selection: $provider.dialect) { ForEach(AIProtocol.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                Section("连接") {
                    TextField("HTTPS 接口地址", text: $provider.baseURL).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    SecureField("API 密钥", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("模型名称", text: $provider.model).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Stepper("回复上限：\(provider.maxTokens)", value: $provider.maxTokens, in: 256...65536, step: 256)
                }
                Section { Text("接口地址和模型名称由服务商提供。保存后，这个服务商会用于新的伴读回复。").font(.footnote).foregroundStyle(.secondary) }
            }.navigationTitle("连接 AI")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") {
                        companion.perform {
                            _ = try ChatRequest.make(provider: provider, key: key, messages: [.init(role: "user", content: "连接配置检查")])
                            try KeychainStore.save(key, for: provider.id)
                            if let index = companion.settings.providers.firstIndex(where: { $0.id == provider.id }) { companion.settings.providers[index] = provider }
                            else { companion.settings.providers.append(provider) }
                            companion.settings.selectedProvider = provider.id; companion.saveSettings()
                            if companion.error == nil { dismiss() }
                        }
                    } }
                }
                .task { companion.perform { key = try KeychainStore.read(provider.id) } }
        }
    }
}

struct CompanionChat: View {
    @State var conversationID: UUID
    var selection: SourcePassage? = nil
    @EnvironmentObject private var companion: CompanionModel
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var editing: ChatMessage?
    @State private var editText = ""
    @State private var showSummary = false
    @State private var showIdentity = false
    @State private var source: SourcePassage?
    @State private var scrollPosition: UUID?
    private var conversation: Conversation? { companion.conversations.first { $0.id == conversationID } }
    private var generating: Bool { companion.activeConversation == conversationID }
    var body: some View {
        VStack(spacing: 0) {
            if let selection {
                Text(selection.text).font(.caption).lineLimit(3).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding().background(.quaternary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if conversation?.messages.isEmpty != false {
                        Text(companion.characters.first { $0.id == conversation?.characterID }?.greeting ?? "想聊些什么？").foregroundStyle(.secondary).padding(.top, 30)
                    }
                    ForEach(conversation?.messages ?? []) { message in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(message.role == "user" ? message.identity?.label ?? companion.settings.userName : companion.characters.first { $0.id == conversation?.characterID }?.name ?? "伙伴").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            if message.content.isEmpty && message.status == "receiving" { ProgressView(companion.memoryStatus ?? "正在阅读与思考…") }
                            else { Text(.init(message.content)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                            if message.status == "interrupted" { Text("回复已中断，可重试").font(.caption).foregroundStyle(.secondary) }
                            if let traces = message.toolTrace, !traces.isEmpty {
                                DisclosureGroup("查询过程（\(traces.count) 步）") {
                                    ForEach(traces) { trace in
                                        VStack(alignment: .leading, spacing: 4) {
                                            Label(trace.title + " · " + (trace.state == "succeeded" ? "完成" : trace.state == "failed" ? "未完成" : trace.state == "interrupted" ? "已停止" : "进行中"), systemImage: trace.state == "succeeded" ? "checkmark.circle" : "magnifyingglass")
                                            if !trace.preview.isEmpty { Text(trace.preview).font(.caption).textSelection(.enabled) }
                                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                                    }
                                }.font(.caption).accessibilityIdentifier("tool-trace")
                            }
                            if let notice = message.retrievalNotice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                            if !message.sources.isEmpty {
                                ScrollView(.horizontal) {
                                    HStack { ForEach(Array(message.sources.enumerated()), id: \.element.id) { index, passage in
                                        Button("来源 \(index + 1)") { showSource(passage) }.font(.caption).buttonStyle(.bordered)
                                    } }
                                }
                            }
                        }.padding(16).background(message.role == "user" ? Color.accentColor.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 16))
                            .id(message.id)
                            .contextMenu {
                                Button("复制", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.content }
                                Button("编辑", systemImage: "pencil") { editing = message; editText = message.content }.disabled(companion.busy)
                                Button("从此处分支", systemImage: "arrow.triangle.branch") { if let id = companion.fork(conversationID, through: message.id) { conversationID = id } }.disabled(companion.busy)
                            }
                    }
                }.padding(.horizontal, 14).padding(.bottom, 20).scrollTargetLayout()
            }.accessibilityIdentifier("chat-messages").scrollPosition(id: $scrollPosition, anchor: .bottom)
                .defaultScrollAnchor(.bottom)
            if generating { Button("停止回复", systemImage: "stop.circle") { companion.stop() }.padding(8) }
            Button("身份：\(companion.settings.currentIdentity.label)", systemImage: "person.crop.circle") { showIdentity = true }
                .font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).accessibilityIdentifier("chat-identity")
            HStack(alignment: .bottom, spacing: 12) {
                TextField(selection == nil ? "聊聊这本书…" : "问问这一段…", text: $draft, axis: .vertical).lineLimit(1...6).padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 16)).accessibilityIdentifier("chat-input")
                Button {
                    let text = draft; companion.send(text, in: conversationID, library: library, selection: selection)
                    if companion.activeConversation == conversationID { draft = ""; scrollPosition = conversation?.messages.last?.id }
                } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 32)) }
                .accessibilityLabel("发送").disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || companion.busy)
            }.padding()
        }.navigationTitle(conversation?.title ?? "伴读").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("返回") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("前情提要", systemImage: "text.alignleft") { showSummary = true } }
                ToolbarItem(placement: .primaryAction) { Button("重新生成", systemImage: "arrow.clockwise") { companion.retry(conversationID, library: library) }.disabled(companion.busy || conversation?.messages.isEmpty != false) }
            }
            .onDisappear { companion.refreshSummary(conversationID, library: library); companion.consolidateMemory(conversationID, library: library, onClose: true) }
            .sheet(isPresented: $showSummary) { NavigationStack { ConversationSummaryView(conversationID: conversationID).toolbar { Button("完成") { showSummary = false } } } }
            .sheet(isPresented: $showIdentity) { NavigationStack { UserMaskSettingsView().toolbar { Button("完成") { showIdentity = false } } } }
            .sheet(item: $editing) { message in
                NavigationStack { TextEditor(text: $editText).padding().navigationTitle("编辑消息").toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { editing = nil } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") { companion.edit(conversationID, messageID: message.id, text: editText); editing = nil } }
                } }
            }
            .sheet(item: $source) { passage in
                NavigationStack { ScrollView { Text(passage.text).textSelection(.enabled).padding(24) }.navigationTitle("核对原文").toolbar { Button("完成") { source = nil } } }
            }
    }
    private func showSource(_ passage: SourcePassage) {
        library.perform {
            guard let book = library.books.first(where: { $0.id == passage.bookID }), !book.removed,
                  let chapter = try library.store?.chapter(passage.chapter, in: book),
                  passage.isValid(in: chapter, scope: ReadingScope(through: book.readThrough)) else { throw MoReadError.invalid("原文或阅读范围已变化，这条来源已失效。") }
            source = passage
        }
    }
}
