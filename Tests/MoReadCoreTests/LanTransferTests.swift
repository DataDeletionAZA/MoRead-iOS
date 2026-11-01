import XCTest
import Network
@testable import MoReadCore

final class LanTransferTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("LanTest-" + UUID().uuidString) }
    private func ready(_ server: LanTransferServer) async throws -> LanTransferState {
        for _ in 0..<100 {
            let state = await server.state
            if state.running { return state }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw MoReadError.invalid("Listener did not start")
    }
    private func request(_ state: LanTransferState, path: String, data: Data? = nil, name: String = "雨后的书店.txt", code: String? = nil) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(state.port)\(path)")!); request.timeoutInterval = 5
        request.setValue(code ?? state.code, forHTTPHeaderField: "X-MoRead-Code")
        if let data {
            request.httpMethod = "POST"; request.httpBody = data
            request.setValue(name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), forHTTPHeaderField: "X-File-Name")
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, try XCTUnwrap(response as? HTTPURLResponse))
    }
    func testHeaderAndFilenameValidation() throws {
        XCTAssertEqual(try LanRequest.filename("..%2F%E5%B0%8F%E8%AF%B4.TXT"), "小说.txt")
        XCTAssertEqual(try LanRequest.filename("C%3A%5CBooks%5Cbook.epub"), "book.epub")
        XCTAssertLessThanOrEqual(try LanRequest.filename(String(repeating: "汉", count: 300).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)! + ".txt").utf8.count, 184)
        for name in ["%00.txt", "%ZZ.txt", "book.html", "..", "a%0D%0A.txt"] { XCTAssertThrowsError(try LanRequest.filename(name)) }
        for header in ["POST /upload HTTP/1.1\r\nHost: local\r\nContent-Length: 1\r\nContent-Length: 2", "POST /upload HTTP/1.1\r\nHost: local\r\nTransfer-Encoding: chunked", "POST /upload HTTP/1.1\r\nHost: local\r\nOrigin: https://foreign.example", "GET / HTTP/1.1\r\nBad Key: value"] {
            XCTAssertThrowsError(try LanRequest.parse(Data(header.utf8)))
        }
        XCTAssertEqual(try LanRequest.parse(Data("GET / HTTP/1.1\r\nHost: local\r\nOrigin: http://local".utf8)).path, "/")
    }
    func testRealUploadsAuthorizationDuplicateNamesRestartAndRemoval() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let server = try LanTransferServer(root: root); try await server.start(); let state = try await ready(server)
        let page = try await request(state, path: "/")
        XCTAssertEqual(page.1.statusCode, 200); XCTAssertTrue(String(decoding: page.0, as: UTF8.self).contains("把故事带到手机上"))
        let wrong = try await request(state, path: "/upload", data: Data("private book".utf8), code: "wrong")
        XCTAssertEqual(wrong.1.statusCode, 403); let empty = await server.state; XCTAssertTrue(empty.received.isEmpty)
        let bytes = Data(String(repeating: "第一章 雨后\n这是一段长长的正文。\n", count: 40_000).utf8)
        let uploaded = try await request(state, path: "/upload", data: bytes)
        XCTAssertEqual(uploaded.1.statusCode, 200)
        let second = try await request(state, path: "/upload", data: Data("second".utf8)); XCTAssertEqual(second.1.statusCode, 200)
        let files = await server.state.received
        XCTAssertEqual(files.count, 2); XCTAssertEqual(Set(files.map(\.name)), ["雨后的书店.txt"]); XCTAssertNotEqual(files[0].url, files[1].url)
        XCTAssertEqual(try Data(contentsOf: files[0].url), bytes); XCTAssertEqual(try Data(contentsOf: files[1].url), Data("second".utf8))
        let status = try await request(state, path: "/status"); XCTAssertTrue(String(decoding: status.0, as: UTF8.self).contains("雨后的书店.txt"))
        await server.stop()
        let reopened = try LanTransferServer(root: root)
        let restored = await reopened.state.received; XCTAssertEqual(Set(restored.map(\.id)), Set(files.map(\.id)))
        try await reopened.remove(files[0].id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files[0].url.path)); XCTAssertTrue(FileManager.default.fileExists(atPath: files[1].url.path))
        try await reopened.start(); let restarted = try await ready(reopened)
        let stale = try await request(restarted, path: "/status", code: "invalidated"); XCTAssertEqual(stale.1.statusCode, 403)
        await reopened.stop()
    }
    func testOversizedInterruptedAndStoppedUploadsNeverBecomeReceivedFiles() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let server = try LanTransferServer(root: root); try await server.start(); let state = try await ready(server)
        let oversized = "POST /upload HTTP/1.1\r\nHost: localhost\r\nX-MoRead-Code: \(state.code)\r\nX-File-Name: book.txt\r\nContent-Length: \(LanTransferServer.maximumFileBytes + 1)\r\n\r\n"
        let response = try await LANProbe.exchange(oversized, port: state.port)
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 413"))
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: state.port)!, using: .tcp)
        connection.start(queue: DispatchQueue(label: "LanTest.partial"))
        connection.send(content: Data("POST /upload HTTP/1.1\r\nHost: localhost\r\nX-MoRead-Code: \(state.code)\r\nX-File-Name: unfinished.txt\r\nContent-Length: 1000000\r\n\r\npartial".utf8), completion: .contentProcessed { _ in })
        for _ in 0..<100 { if await server.state.incomingName != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
        let receiving = await server.state; XCTAssertEqual(receiving.incomingName, "unfinished.txt")
        await server.stop(); connection.cancel()
        let stopped = await server.state; XCTAssertFalse(stopped.running); XCTAssertNil(stopped.incomingName); XCTAssertTrue(stopped.received.isEmpty)
        let restored = try LanTransferServer(root: root); let files = await restored.state.received; XCTAssertTrue(files.isEmpty)
    }
}

private final class LANProbe: @unchecked Sendable {
    let connection: NWConnection
    let continuation: CheckedContinuation<String, Error>
    let queue = DispatchQueue(label: "LanTest.probe")
    var data = Data(), done = false
    init(port: UInt16, continuation: CheckedContinuation<String, Error>) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp); self.continuation = continuation
    }
    static func exchange(_ raw: String, port: UInt16) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let probe = LANProbe(port: port, continuation: continuation)
            probe.connection.start(queue: probe.queue)
            probe.connection.send(content: Data(raw.utf8), completion: .contentProcessed { _ in })
            probe.receive()
            probe.queue.asyncAfter(deadline: .now() + 5) { probe.finish(error: MoReadError.invalid("TCP timeout")) }
        }
    }
    func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            if let data { self.data.append(data) }
            if complete || error != nil { self.finish(error: error) } else { self.receive() }
        }
    }
    func finish(error: Error?) {
        guard !done else { return }; done = true; connection.cancel()
        if let error, data.isEmpty { continuation.resume(throwing: error) }
        else { continuation.resume(returning: String(decoding: data, as: UTF8.self)) }
    }
}
