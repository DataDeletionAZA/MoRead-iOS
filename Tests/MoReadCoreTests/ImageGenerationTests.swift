import XCTest
import CoreGraphics
import ImageIO
import ReadiumZIPFoundation
@testable import MoReadCore

final class ImageGenerationTests: XCTestCase {
    func testIllustrationToolScopeReferencesAndBackup() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = folder.appendingPathComponent("library"), store = try LibraryStore(root: root)
        let visible = "灯🌙塔。灯🌙塔。"
        let chapter = Chapter(id: 0, title: "第一章", text: visible + "秘密。")
        var book = try store.importBook(title: "灯塔", chapters: [chapter, .init(id: 1, title: "后文", text: "未读内容。")])
        book.readThrough = .init(offset: visible.utf16.count); try store.save(book)
        let source = SourcePassage(bookID: book.id, chapter: chapter, offset: 5, text: "灯🌙塔。")
        func call(_ fields: [String: Any]) throws -> ChatToolCall { .init(id: "image", name: "generate_illustration", arguments: String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self)) }
        func request(_ fields: [String: Any]) throws -> IllustrationToolRequest { try .init(call: call(fields), book: book, sources: [source], store: store) }
        XCTAssertFalse(try ReaderTools.specs(currentBook: book.id, memory: false).contains { $0.name == "generate_illustration" })
        XCTAssertFalse(try ReaderTools.specs(currentBook: nil, memory: false, imageGeneration: true).contains { $0.name == "generate_illustration" })
        XCTAssertFalse(try ReaderTools.specs(currentBook: book.id, memory: false, imageGeneration: true, enabled: []).contains { $0.name == "generate_illustration" })
        XCTAssertTrue(try ReaderTools.specs(currentBook: book.id, memory: false, imageGeneration: true).contains { $0.name == "generate_illustration" })
        let invalid: [[String: Any]] = [
            ["prompt": ""], ["prompt": "scene", "chapter_number": 2], ["prompt": "scene", "char_offset": 11],
            ["prompt": "scene", "char_offset": 2], ["prompt": "scene", "char_offset": true],
            ["prompt": "scene", "source_text": "秘密。"], ["prompt": "scene", "source_text": "灯🌙塔。"],
            ["prompt": "scene", "source_text": "灯🌙塔。", "char_offset": 1], ["prompt": "scene", "source_ref": source.id],
            ["prompt": "scene", "source_text": "灯🌙塔。", "source_ref": "missing"]
        ]
        for fields in invalid { XCTAssertThrowsError(try request(fields)) }
        let anchored = try request(["prompt": "A lighthouse", "source_text": "灯🌙塔。", "source_ref": source.id])
        XCTAssertEqual(anchored.source, source); XCTAssertEqual(anchored.anchor.offset, 5)
        XCTAssertEqual(try request(["prompt": "A lighthouse", "source_text": "灯🌙塔。", "char_offset": 0]).anchor.offset, 0)
        XCTAssertNil(try request(["prompt": "An imagined lighthouse"]).source)
        let character = UUID()
        let item = try store.saveIllustration(data: picture(), bookID: book.id, prompt: anchored.prompt, model: "fixture", source: anchored.source, through: book.readThrough, anchor: anchored.anchor, characterID: character, characterName: "伙伴")
        let reference = IllustrationReference(item)
        var trace = ChatToolTrace(call: try call(["prompt": anchored.prompt]), title: "生成插图"); trace.state = "succeeded"; trace.illustration = reference
        var message = ChatMessage(role: "assistant", content: "已生成插图。"); message.toolTrace = [trace]
        var conversation = Conversation(title: "灯塔", bookID: book.id, characterID: character); conversation.messages = [message]
        let companion = try CompanionStore(root: root); try companion.save(conversation)
        var global = conversation; global.bookID = nil; XCTAssertThrowsError(try companion.save(global))
        var wrong = conversation; wrong.messages[0].role = "user"; XCTAssertThrowsError(try companion.save(wrong))
        let backup = folder.appendingPathComponent("chat-image.zip"); _ = try await BackupArchive.create(root: root, output: backup)
        try store.deleteIllustration(item)
        let prepared = try await BackupArchive.prepare(backup, beside: root); try BackupArchive.activate(prepared, replacing: root)
        XCTAssertEqual(try companion.conversations().first?.messages.first?.toolTrace?.first?.illustration, reference)
        let restored = try XCTUnwrap(store.illustrations(for: book.id).first)
        XCTAssertEqual(restored.anchor, anchored.anchor); XCTAssertEqual(restored.characterID, character); XCTAssertEqual(restored.characterName, "伙伴")
        XCTAssertEqual(try store.illustrationData(restored), try picture())
    }
    func testImageModelAssignmentStandalonePriorityAndCredentialSelection() throws {
        var settings = try JSONDecoder().decode(CompanionSettings.self, from: Data(#"{"providers":[],"userName":"读者"}"#.utf8))
        var provider = AIProvider(); provider.model = "image-model"; provider.baseURL = "https://images.example/v1"
        settings.providers = [provider]; settings.selectedProvider = provider.id; settings.batchProvider = provider.id
        XCTAssertNil(settings.imageConnection)
        try settings.assignProvider(provider.id, to: .image)
        let assigned = try XCTUnwrap(settings.imageConnection)
        XCTAssertEqual(assigned.credentialID, provider.id); XCTAssertEqual(assigned.settings.model, provider.model)
        XCTAssertEqual(assigned.settings.baseURL, provider.baseURL)
        var standalone = ImageGenerationSettings(); standalone.preset(.novelAI); settings.imageGeneration = standalone
        XCTAssertEqual(settings.imageConnection?.credentialID, ImageGenerationService.novelAI.credentialID)
        XCTAssertEqual(settings.imageConnection?.settings, standalone)
        standalone.useAssignedModel = true; standalone.service = .chat; standalone.endpoint = "chat/completions"; settings.imageGeneration = standalone
        let chat = try XCTUnwrap(settings.imageConnection)
        XCTAssertEqual(chat.credentialID, provider.id); XCTAssertEqual(chat.settings.service, .chat)
        XCTAssertEqual(try ImageGenerationClient.request(settings: chat.settings, key: "fixture", prompt: "scene").url?.absoluteString, "https://images.example/v1/chat/completions")
        let restored = try JSONDecoder().decode(CompanionSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored.imageConnection, chat)
        settings.providers[0].model = "another-image-model"; XCTAssertNotEqual(settings.imageConnection, chat)
        settings.providers = []; XCTAssertNil(settings.imageConnection)
        standalone.useAssignedModel = false; settings.imageGeneration = standalone
        XCTAssertEqual(settings.imageConnection?.credentialID, ImageGenerationService.chat.credentialID)
        try settings.assignProvider(nil, to: .image); XCTAssertNotNil(settings.imageConnection)
    }
    private func picture() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 12, height: 18, bitsPerComponent: 8, bytesPerRow: 48, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.5, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 12, height: 18))
        let data = NSMutableData(), destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil); XCTAssertTrue(CGImageDestinationFinalize(destination)); return data as Data
    }
    func testProviderPayloadsAndCredentialBoundaries() throws {
        XCTAssertEqual(IllustrationPrompt.messages("书店", service: .novelAI).last?.content, "书店")
        XCTAssertEqual(try IllustrationPrompt.validate("Tags: 1girl, reading, reading, book", service: .novelAI), "1girl, reading, book")
        XCTAssertThrowsError(try IllustrationPrompt.validate("安静的书店", service: .novelAI))
        var settings = ImageGenerationSettings(); settings.preset(.images)
        let request = try ImageGenerationClient.request(settings: settings, key: "fixture", prompt: "A quiet bookstore")
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/images/generations")
        var body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["size"] as? String, "1024x1024"); XCTAssertNil(body["response_format"])
        XCTAssertNotNil(try ImageGenerationClient.downloadRequest(reference: "https://api.openai.com/generated.png", generation: request).value(forHTTPHeaderField: "Authorization"))
        for address in ["https://cdn.example.com/a.png", "https://api.openai.com:444/a.png"] {
            XCTAssertNil(try ImageGenerationClient.downloadRequest(reference: address, generation: request).value(forHTTPHeaderField: "Authorization"))
        }
        for address in ["http://example.com/a.png", "https://user:pass@example.com/a.png", "file:///tmp/a.png"] { XCTAssertThrowsError(try ImageGenerationClient.downloadRequest(reference: address, generation: request)) }
        settings.baseURL += "/images/generations"
        XCTAssertEqual(try ImageGenerationClient.request(settings: settings, key: "fixture", prompt: "scene").url, request.url)
        settings.preset(.chat)
        let chat = try ImageGenerationClient.request(settings: settings, key: "fixture", prompt: "scene")
        body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(chat.httpBody)) as? [String: Any])
        XCTAssertEqual(body["modalities"] as? [String], ["image", "text"]); XCTAssertNil(body["size"]); XCTAssertEqual(body["stream"] as? Bool, false)
        settings.preset(.novelAI); settings.positivePrompt = "best quality"; settings.negativePrompt = "blur"
        body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(ImageGenerationClient.request(settings: settings, key: "fixture", prompt: "bookshop").httpBody)) as? [String: Any])
        XCTAssertEqual(body["input"] as? String, "best quality, bookshop")
        let parameters = try XCTUnwrap(body["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["width"] as? Int, 832); XCTAssertEqual(parameters["n_samples"] as? Int, 1); XCTAssertNotNil(parameters["v4_prompt"])
        XCTAssertEqual(parameters["negative_prompt"] as? String, "blur")
        settings.size = "833x1216"; XCTAssertThrowsError(try ImageGenerationClient.request(settings: settings, key: "fixture", prompt: "scene"))
        settings.preset(.images)
        for path in ["../images", "images?key=bad", "https://other.example/images", "images/%2e%2e/request"] {
            settings.endpoint = path; XCTAssertThrowsError(try ImageGenerationClient.request(settings: settings, key: "fixture", prompt: "scene"))
        }
        settings.preset(.images)
        XCTAssertThrowsError(try ImageGenerationClient.request(settings: settings, key: "secret\nInjected", prompt: "scene"))
        XCTAssertThrowsError(try ImageGenerationClient.request(settings: settings, key: "fixture", prompt: String(repeating: "字", count: 24_001)))
    }
    func testImageResponsesAndBoundedZipExtraction() async throws {
        let fallback = try await IllustrationPrompt.compose("A quiet shop", service: .images, provider: nil, key: "")
        XCTAssertEqual(fallback, "A quiet shop")
        do { _ = try await IllustrationPrompt.compose("安静的书店", service: .novelAI, provider: nil, key: ""); XCTFail("Chinese prompt sent to NovelAI without conversion") } catch { }
        let image = try picture(), encoded = image.base64EncodedString(), dataURI = "data:image/png;base64," + encoded
        let responses: [[String: Any]] = [
            ["data": [["b64_json": encoded]]],
            ["choices": [["message": ["images": [["image_url": ["url": dataURI]]]]]]],
            ["choices": [["message": ["content": [["type": "image_url", "image_url": ["url": dataURI]]]]]]],
            ["choices": [["message": ["content": "画面：" + dataURI]]]]
        ]
        for response in responses {
            let reference = try ImageGenerationClient.imageReference(JSONSerialization.data(withJSONObject: response), service: .chat)
            XCTAssertEqual(try ImageGenerationClient.embeddedImage(reference), image)
        }
        let markdown = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": "![scene](https://example.com/picture.png)"]]]])
        XCTAssertEqual(try ImageGenerationClient.imageReference(markdown, service: .chat), "https://example.com/picture.png")
        XCTAssertThrowsError(try ImageGenerationClient.imageReference(Data("{}".utf8), service: .images))
        XCTAssertThrowsError(try ImageGenerationClient.embeddedImage("data:image/png;base64,AAAA"))
        XCTAssertThrowsError(try ImageGenerationClient.imageProperties(Data("<svg></svg>".utf8)))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: folder) }
        let png = folder.appendingPathComponent("image.png"); try image.write(to: png)
        let zip = folder.appendingPathComponent("image.zip"), archive = try await Archive(url: zip, accessMode: .create)
        try await archive.addEntry(with: "image.png", fileURL: png, compressionMethod: .deflate)
        let unpacked = try await ImageGenerationClient.unzipImage(Data(contentsOf: zip)); XCTAssertEqual(unpacked, image)
        do { _ = try await ImageGenerationClient.unzipImage(Data(repeating: 0, count: 100)); XCTFail("Invalid archive accepted") } catch { }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var settings = ImageGenerationSettings(); settings.preset(.images)
            return try await ImageGenerationClient.generate(settings: settings, key: "fixture", prompt: "scene")
        }
        do { _ = try await cancelled.value; XCTFail("Cancelled generation ran") } catch is CancellationError { }
    }
    func testIllustrationStorageScopesCategoriesBackupAndBodyCleanup() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = folder.appendingPathComponent("library"), store = try LibraryStore(root: root)
        let chapter = Chapter(id: 0, title: "第一章", text: "安静的书店。后续秘密。")
        var book = try store.importBook(title: "书店", chapters: [chapter]); book.readThrough = .init(offset: 6); try store.save(book)
        let passage = SourcePassage(bookID: book.id, chapter: chapter, offset: 0, text: "安静的书店。"), image = try picture()
        let item = try store.saveIllustration(data: image, bookID: book.id, prompt: "A bookshop", originalPrompt: "安静的书店", model: "fixture", source: passage, through: book.readThrough)
        XCTAssertEqual(try store.illustrationData(item), image); XCTAssertTrue(item.visible(in: book))
        var rolledBack = book; rolledBack.readThrough.offset = 3; XCTAssertFalse(item.visible(in: rolledBack))
        var invalid = passage; invalid.text = chapter.text
        XCTAssertThrowsError(try store.saveIllustration(data: image, bookID: book.id, prompt: "scene", model: "fixture", source: invalid, through: book.readThrough))
        XCTAssertEqual(try store.illustrations(for: book.id).count, 1)
        try store.categorizeIllustration(item, category: "场景"); XCTAssertEqual(try store.illustrations(for: book.id).first?.category, "场景")
        XCTAssertThrowsError(try store.categorizeIllustration(item, category: String(repeating: "长", count: 41)))
        let settingsStore = try CompanionStore(root: root); var settings = CompanionSettings(); var images = ImageGenerationSettings(); images.preset(.novelAI); settings.imageGeneration = images; try settingsStore.save(settings)
        let backup = folder.appendingPathComponent("pictures.zip"); _ = try await BackupArchive.create(root: root, output: backup)
        try store.deleteIllustration(item); XCTAssertTrue(try store.illustrations(for: book.id).isEmpty)
        let prepared = try await BackupArchive.prepare(backup, beside: root); try BackupArchive.activate(prepared, replacing: root)
        XCTAssertEqual(try store.illustrationData(item), image); XCTAssertEqual(try CompanionStore(root: root).settings().imageGeneration, images)
        XCTAssertEqual(try store.illustrations(for: book.id).first?.originalPrompt, "安静的书店")
        let cleared = try store.clearBody(book); XCTAssertTrue(item.visible(in: cleared)); XCTAssertEqual(try store.illustrationData(item), image)
        XCTAssertThrowsError(try store.saveIllustration(data: image, bookID: book.id, prompt: "scene", model: "fixture", through: book.readThrough))
        try Data("broken".utf8).write(to: store.illustrationURL(item))
        let corrupt = folder.appendingPathComponent("corrupt.zip"); _ = try await BackupArchive.create(root: root, output: corrupt)
        do { _ = try await BackupArchive.prepare(corrupt, beside: root); XCTFail("Corrupt image restored") } catch { }
    }
}
