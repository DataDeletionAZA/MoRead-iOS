import SwiftUI
import CoreImage.CIFilterBuiltins
import MoReadCore

struct LanTransferView: View {
    let group: UUID?
    let collection: UUID?
    let close: () -> Void
    @StateObject private var transfer: LanTransferModel
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.scenePhase) private var phase
    @State private var staging = false
    @State private var copied = false
    init(root: URL, group: UUID?, collection: UUID?, close: @escaping () -> Void) {
        self.group = group; self.collection = collection; self.close = close
        _transfer = StateObject(wrappedValue: LanTransferModel(root: root))
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("让电脑和 iPhone 连接同一个 Wi-Fi，在电脑浏览器打开下面的地址。").font(.callout)
                    ForEach(transfer.state.addresses, id: \.self) { address in
                        Text(address).font(.system(.body, design: .monospaced)).textSelection(.enabled).accessibilityIdentifier("lan-address")
                    }
                    if transfer.state.running {
                        LabeledContent("连接码", value: transfer.state.code).accessibilityIdentifier("lan-code")
                        if let link = transfer.link {
                            Button(copied ? "地址已复制" : "复制地址与连接码", systemImage: "doc.on.doc") { UIPasteboard.general.string = link; copied = true }
                            ShareLink("分享传书地址", item: link)
                            DisclosureGroup("显示二维码") {
                                if let image = transfer.qr {
                                    Image(uiImage: image).interpolation(.none).resizable().scaledToFit().frame(maxWidth: 200).padding(12).background(.white).accessibilityLabel("传书地址二维码")
                                }
                            }
                        }
                    }
                    if transfer.state.starting { ProgressView("正在开启…") }
                    if let message = transfer.error ?? transfer.state.message { Text(message).foregroundStyle(.secondary).accessibilityIdentifier("lan-message") }
                    Button(transfer.state.running || transfer.state.starting ? "停止接收" : "开启接收") { copied = false; transfer.toggle() }
                        .accessibilityIdentifier("lan-toggle")
                } header: { Text(transfer.state.running ? "正在等待电脑传书" : "接收已停止") } footer: {
                    Text("传输时保持此页面在前台。离开页面或锁屏会停止接收；已经收完整的文件会保留。")
                }
                if let name = transfer.state.incomingName {
                    Section("正在接收") {
                        Text(name)
                        ProgressView(value: Double(transfer.state.receivedBytes), total: Double(max(1, transfer.state.expectedBytes)))
                        Text("\(transfer.state.receivedBytes.formatted(.byteCount(style: .file))) / \(transfer.state.expectedBytes.formatted(.byteCount(style: .file)))").font(.caption)
                    }
                }
                Section("已接收 \(transfer.state.received.count) 个文件") {
                    if transfer.state.received.isEmpty { Text("电脑上传成功后，文件会显示在这里。").foregroundStyle(.secondary) }
                    ForEach(transfer.state.received) { file in
                        HStack {
                            VStack(alignment: .leading) { Text(file.name); Text(file.bytes.formatted(.byteCount(style: .file))).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Button(role: .destructive) { transfer.remove(file.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).accessibilityLabel("移除待导入文件 " + file.name)
                        }.accessibilityIdentifier("lan-received-" + file.name)
                    }
                }
            }.disabled(staging)
            .navigationTitle("局域网传书").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { transfer.stop(); close() }.disabled(staging) } }
            .safeAreaInset(edge: .bottom) {
                if staging { ProgressView("正在准备导入…").padding() }
                else if !transfer.state.received.isEmpty {
                    Button("全部导入书架（\(transfer.state.received.count)）") { importFiles() }.buttonStyle(.borderedProminent).padding().accessibilityIdentifier("lan-import")
                }
            }
            .interactiveDismissDisabled(staging)
            .task { await transfer.open() }
            .onDisappear { transfer.stop(); UIApplication.shared.isIdleTimerDisabled = false }
            .onChange(of: transfer.state.running) { _, active in UIApplication.shared.isIdleTimerDisabled = active }
            .onChange(of: phase) { _, value in if value == .background { transfer.stop(); UIApplication.shared.isIdleTimerDisabled = false } }
            .onChange(of: library.maintenance) { _, value in if value { transfer.stop(); close() } }
        }
    }
    private func importFiles() {
        guard !staging, !library.importing, !library.maintenance else { return }
        staging = true
        Task {
            await transfer.stopAndWait()
            let files = transfer.state.received
            let accepted = await library.queueImports(files.map(\.url), group: group, collection: collection, startImmediately: false)
            for file in files where accepted.contains(file.url) { await transfer.removeAndWait(file.id) }
            staging = false
            if !accepted.isEmpty { close() }
        }
    }
}

@MainActor private final class LanTransferModel: ObservableObject {
    @Published var state = LanTransferState()
    @Published var error: String?
    @Published var qr: UIImage?
    private var server: LanTransferServer?
    private let root: URL
    private var opened = false
    private var permitted = true
    var link: String? { state.addresses.first.map { $0 + "/#code=" + state.code } }
    init(root: URL) { self.root = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-Transfers", isDirectory: true) }
    func open() async {
        guard !opened else { return }; opened = true
        do {
            server = try LanTransferServer(root: root, onChange: { [weak self] state in Task { await self?.update(state) } })
            if let server {
                update(await server.state)
                guard permitted, !Task.isCancelled else { return }
                try await server.start()
                if !permitted || Task.isCancelled { await server.stop() }
            }
        } catch { self.error = error.localizedDescription }
    }
    private func update(_ value: LanTransferState) {
        guard value.revision >= state.revision else { return }
        let previous = link; state = value
        if previous != link {
            qr = nil
            if let link {
                let filter = CIFilter.qrCodeGenerator(); filter.message = Data(link.utf8)
                if let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)), let image = CIContext().createCGImage(output, from: output.extent) { qr = UIImage(cgImage: image) }
            }
        }
    }
    func toggle() {
        error = nil; permitted = true
        Task {
            do {
                guard let server else { opened = false; await open(); return }
                if state.running || state.starting { await server.stop() } else if permitted { try await server.start() }
                if !permitted { await server.stop() }
            } catch { self.error = error.localizedDescription }
        }
    }
    func stop() { permitted = false; Task { await stopAndWait() } }
    func stopAndWait() async { permitted = false; if let server { await server.stop(); update(await server.state) } }
    func remove(_ id: UUID) { Task { await removeAndWait(id) } }
    func removeAndWait(_ id: UUID) async {
        do { try await server?.remove(id); if let server { update(await server.state) } }
        catch { self.error = error.localizedDescription }
    }
}
