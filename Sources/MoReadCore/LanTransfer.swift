import Foundation
import Network
import Darwin

public struct LanReceivedFile: Identifiable, Sendable {
    public let id: UUID
    public let url: URL
    public let bytes: Int
    public var name: String { url.lastPathComponent }
}

public struct LanTransferState: Sendable {
    public var revision = 0
    public var running = false
    public var starting = false
    public var port: UInt16 = 0
    public var addresses: [String] = []
    public var code = ""
    public var received: [LanReceivedFile] = []
    public var incomingName: String?
    public var receivedBytes = 0
    public var expectedBytes = 0
    public var message: String?
    public init() {}
}

struct LanRequest {
    let method: String
    let path: String
    let headers: [String: String]
    static let maximumHeader = 16 * 1024
    static func parse(_ data: Data) throws -> Self {
        guard data.count <= maximumHeader, let text = String(data: data, encoding: .utf8) else { throw MoReadError.invalid("请求头过长或格式无效。") }
        let lines = text.components(separatedBy: "\r\n")
        let request = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard request.count == 3, ["HTTP/1.0", "HTTP/1.1"].contains(String(request[2])) else { throw MoReadError.invalid("请求格式无效。") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw MoReadError.invalid("请求头格式无效。") }
            let key = String(line[..<colon]).lowercased(), value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, key.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                  !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }), headers[key] == nil else { throw MoReadError.invalid("请求头重复或格式无效。") }
            headers[key] = value
        }
        guard let host = headers["host"], !host.isEmpty, !host.contains(" "), !host.contains("/"),
              headers["transfer-encoding"] == nil else { throw MoReadError.invalid("请使用浏览器页面上传完整文件。") }
        if let origin = headers["origin"], origin != "http://" + host { throw MoReadError.invalid("请从手机显示的传书地址打开页面。") }
        return Self(method: String(request[0]), path: String(request[1]), headers: headers)
    }
    static func filename(_ raw: String?) throws -> String {
        guard let raw, raw.utf8.count <= 4096, let decoded = raw.removingPercentEncoding,
              !decoded.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw MoReadError.invalid("文件名无效。") }
        let leaf = decoded.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? ""
        let ext = (leaf as NSString).pathExtension.lowercased()
        guard ["txt", "epub"].contains(ext) else { throw MoReadError.invalid("只支持 TXT 和 EPUB 文件。") }
        let original = (leaf as NSString).deletingPathExtension.replacingOccurrences(of: ":", with: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        var base = ""
        for character in original { if base.utf8.count + String(character).utf8.count > 180 { break }; base.append(character) }
        if base.isEmpty || base == "." || base == ".." { base = "未命名书籍" }
        return base + "." + ext
    }
}

public actor LanTransferServer {
    public static let maximumFileBytes = 200 * 1024 * 1024
    private static let maximumSessionBytes = 2 * 1024 * 1024 * 1024
    public private(set) var state = LanTransferState()
    private let root: URL
    private let publish: @Sendable (LanTransferState) -> Void
    private let queue = DispatchQueue(label: "MoRead.LAN")
    private var listener: NWListener?
    private var generation = UUID()
    private var timer: Task<Void, Never>?
    private var connections: [UUID: Connection] = [:]
    private var uploading: UUID?
    private var sessionBytes = 0
    private var failedCodes = 0
    private var codeWindow = Date()
    private struct Connection {
        let network: NWConnection
        var header = Data()
        var started = Date()
        var activity = Date()
        var name: String?
        var temporary: URL?
        var handle: FileHandle?
        var expected = 0
        var received = 0
    }
    public init(root: URL, onChange: @escaping @Sendable (LanTransferState) -> Void = { _ in }) throws {
        self.root = root; publish = onChange
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for directory in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let id = UUID(uuidString: directory.lastPathComponent), try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
                  let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]), files.count == 1, let url = files.first,
                  ["txt", "epub"].contains(url.pathExtension.lowercased()) else { continue }
            let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard attributes.isRegularFile == true, attributes.isSymbolicLink != true, let bytes = attributes.fileSize, (1...Self.maximumFileBytes).contains(bytes) else { continue }
            state.received.append(.init(id: id, url: url, bytes: bytes))
        }
    }
    private func changed() { state.revision += 1; publish(state) }
    public func start() throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.prohibitedInterfaceTypes = [.cellular]
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener; generation = UUID(); let token = generation
        state.starting = true; state.message = nil; state.code = String(Int.random(in: 100000...999999))
        sessionBytes = state.received.reduce(0) { $0 + $1.bytes }; failedCodes = 0; codeWindow = Date(); changed()
        listener.stateUpdateHandler = { [weak self] value in Task { await self?.listenerState(value, token: token) } }
        listener.newConnectionHandler = { [weak self] connection in Task { await self?.accept(connection, token: token) } }
        listener.start(queue: queue)
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                await self?.expire(token: token)
            }
        }
    }
    private func listenerState(_ value: NWListener.State, token: UUID) {
        guard generation == token else { return }
        switch value {
        case .ready:
            state.starting = false; state.running = true; state.port = listener?.port?.rawValue ?? 0
            state.addresses = Self.addresses().map { "http://\($0):\(state.port)" }
            state.message = state.addresses.isEmpty ? "未找到 Wi-Fi 地址，请检查网络连接后重新开启。" : nil
            changed()
        case .waiting: state.message = "正在等待局域网连接或访问许可…"; changed()
        case .failed: stop(); state.message = "无法开启传书，请检查 Wi-Fi 和系统的局域网访问权限后重试。"; changed()
        default: break
        }
    }
    public func stop() {
        generation = UUID(); listener?.cancel(); listener = nil; timer?.cancel(); timer = nil
        for id in Array(connections.keys) { close(id) }
        uploading = nil; state.running = false; state.starting = false; state.port = 0; state.addresses = []; state.code = ""
        state.incomingName = nil; state.receivedBytes = 0; state.expectedBytes = 0; changed()
    }
    public func remove(_ id: UUID) throws {
        guard let file = state.received.first(where: { $0.id == id }) else { return }
        try FileManager.default.removeItem(at: file.url.deletingLastPathComponent())
        sessionBytes = max(0, sessionBytes - file.bytes)
        state.received.removeAll { $0.id == id }; changed()
    }
    private func accept(_ connection: NWConnection, token: UUID) {
        guard generation == token, state.running, connections.count < 8 else { connection.cancel(); return }
        let id = UUID(); connections[id] = Connection(network: connection)
        connection.start(queue: queue); receive(id)
    }
    private func receive(_ id: UUID) {
        connections[id]?.network.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            Task { await self?.received(id, data: data, ended: complete || error != nil) }
        }
    }
    private func received(_ id: UUID, data: Data?, ended: Bool) {
        guard var connection = connections[id] else { return }
        connection.activity = Date(); connections[id] = connection
        do {
            if connection.name == nil {
                connection.header.append(data ?? Data()); connections[id] = connection
                if let end = connection.header.range(of: Data("\r\n\r\n".utf8)) {
                    let head = try LanRequest.parse(Data(connection.header[..<end.lowerBound]))
                    let body = Data(connection.header[end.upperBound...])
                    try route(head, id: id)
                    if connections[id]?.name != nil { try append(body, id: id) }
                } else if connection.header.count > LanRequest.maximumHeader { throw MoReadError.invalid("请求头过长。") }
            } else { try append(data ?? Data(), id: id) }
            guard connections[id] != nil else { return }
            if ended { throw MoReadError.invalid("连接已中断，请重新上传这个文件。") }
            receive(id)
        } catch { respond(id, status: 400, error: error.localizedDescription) }
    }
    private func route(_ request: LanRequest, id: UUID) throws {
        if request.method == "GET", let asset = ["/": ("index", "html", "text/html; charset=utf-8"), "/app.js": ("app", "js", "application/javascript; charset=utf-8"), "/style.css": ("style", "css", "text/css; charset=utf-8")][request.path] {
            guard let url = Bundle.module.url(forResource: asset.0, withExtension: asset.1, subdirectory: "LanTransfer") else { throw MoReadError.invalid("传书页面不可用。") }
            respond(id, body: try Data(contentsOf: url), type: asset.2); return
        }
        guard (request.method == "POST" && request.path == "/upload") || (request.method == "GET" && request.path == "/status") else { respond(id, status: 404, error: "没有这个地址。"); return }
        if Date().timeIntervalSince(codeWindow) > 60 { failedCodes = 0; codeWindow = Date() }
        guard failedCodes < 20 else { respond(id, status: 429, error: "连接码尝试过多，请一分钟后重试。"); return }
        guard request.headers["x-moread-code"] == state.code, !state.code.isEmpty else { failedCodes += 1; respond(id, status: 403, error: "连接码不正确，请查看手机当前显示的六位数字。"); return }
        if request.path == "/status" {
            respond(id, body: try JSONSerialization.data(withJSONObject: ["received": state.received.map { ["name": $0.name, "bytes": $0.bytes] as [String: Any] }])); return
        }
        guard uploading == nil else { respond(id, status: 409, error: "正在接收另一个文件，请稍后重试。"); return }
        guard let raw = request.headers["content-length"], !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }), let length = Int(raw), length > 0 else { throw MoReadError.invalid("文件为空或缺少有效长度。") }
        guard length <= Self.maximumFileBytes, sessionBytes <= Self.maximumSessionBytes - length, state.received.count < 200 else { respond(id, status: 413, error: "单文件最多 200 MB，每次最多 2 GB、200 个文件；请先导入或移除已接收文件。"); return }
        if let expect = request.headers["expect"], expect.lowercased() != "100-continue" { throw MoReadError.invalid("不支持这种上传请求。") }
        let name = try LanRequest.filename(request.headers["x-file-name"])
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("MoReadReceive-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { throw MoReadError.invalid("无法准备接收文件，请检查剩余空间。") }
        let handle: FileHandle
        do { handle = try FileHandle(forWritingTo: temporary) } catch { try? FileManager.default.removeItem(at: temporary); throw error }
        connections[id]?.header = Data(); connections[id]?.name = name; connections[id]?.temporary = temporary; connections[id]?.handle = handle; connections[id]?.expected = length
        uploading = id; state.incomingName = name; state.receivedBytes = 0; state.expectedBytes = length; changed()
        if request.headers["expect"] != nil { connections[id]?.network.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { _ in }) }
    }
    private func append(_ data: Data, id: UUID) throws {
        guard var connection = connections[id], let handle = connection.handle, let temporary = connection.temporary, let name = connection.name else { return }
        guard data.count <= connection.expected - connection.received else { throw MoReadError.invalid("收到的内容超过声明长度。") }
        try handle.write(contentsOf: data); connection.received += data.count; connections[id] = connection
        if connection.received - state.receivedBytes >= 256 * 1024 || connection.received == connection.expected { state.receivedBytes = connection.received; changed() }
        guard connection.received == connection.expected else { return }
        try handle.synchronize(); try handle.close(); connections[id]?.handle = nil
        let fileID = UUID(), directory = root.appendingPathComponent(fileID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(name)
        do { try FileManager.default.moveItem(at: temporary, to: target) } catch { try? FileManager.default.removeItem(at: directory); throw error }
        state.received.append(.init(id: fileID, url: target, bytes: connection.received)); sessionBytes += connection.received
        respond(id, body: Data(#"{"ok":true}"#.utf8))
    }
    private func respond(_ id: UUID, status: Int = 200, body: Data = Data(), type: String = "application/json; charset=utf-8", error: String? = nil) {
        guard let network = connections[id]?.network else { return }
        let body = error.flatMap { try? JSONSerialization.data(withJSONObject: ["error": $0]) } ?? body
        let headers = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'self'; style-src 'self' 'unsafe-inline'; object-src 'none'; frame-ancestors 'none'; base-uri 'none'\r\n\r\n"
        close(id, cancelNetwork: false)
        network.send(content: Data(headers.utf8) + body, completion: .contentProcessed { _ in network.cancel() })
    }
    private func close(_ id: UUID, cancelNetwork: Bool = true) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        try? connection.handle?.close()
        if let temporary = connection.temporary { try? FileManager.default.removeItem(at: temporary) }
        if cancelNetwork { connection.network.cancel() }
        if uploading == id { uploading = nil; state.incomingName = nil; state.receivedBytes = 0; state.expectedBytes = 0; changed() }
    }
    private func expire(token: UUID) {
        guard generation == token else { return }
        for (id, connection) in connections where Date().timeIntervalSince(connection.activity) > 30 || Date().timeIntervalSince(connection.started) > 1800 { respond(id, status: 408, error: "传输超时，请重新上传。") }
    }
    private static func addresses() -> [String] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }
        var results: Set<String> = [], item: UnsafeMutablePointer<ifaddrs>? = first
        while let current = item {
            defer { item = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET), String(cString: current.pointee.ifa_name).hasPrefix("en"), current.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 { results.insert(String(cString: host)) }
        }
        return results.sorted()
    }
}
