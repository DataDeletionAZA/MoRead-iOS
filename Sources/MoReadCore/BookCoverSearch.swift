import Foundation

public struct OnlineBookCover: Identifiable, Hashable, Sendable {
    public var id: String { imageURL }
    public let title: String
    public let author: String
    public let imageURL: String
    public let pageURL: String
    public let source: String
}
public struct BookCoverSearchResult: Sendable {
    public let covers: [OnlineBookCover]
    public let queries: [String]
    public let notices: [String]
    public init(covers: [OnlineBookCover], queries: [String], notices: [String] = []) { self.covers = covers; self.queries = queries; self.notices = notices }
}

public enum BookCoverSearch {
    public static func queries(title: String, author: String, generated: String? = nil) throws -> [String] {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines), author = author.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.utf16.count <= 240, author.utf16.count <= 160,
              !(title + author).unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw MoReadError.invalid("请填写不超过 240 个字符的书名和 160 个字符的作者。") }
        func quote(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: " ") + "\"" }
        let fallback = quote(title) + (author.isEmpty ? "" : " " + quote(author)) + " 书籍封面 book cover"
        var results: [String] = []
        for raw in (generated ?? "").prefix(8192).components(separatedBy: .newlines) {
            var line = raw.replacingOccurrences(of: "^[\\s\\-*•\\d.)、]+", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.contains("```"), line.localizedCaseInsensitiveContains("cover") || line.contains("封面") else { continue }
            line = TextBoundary.prefix(line, end: 240)
            if !line.localizedCaseInsensitiveContains(title) { line = quote(title) + " " + line }
            guard !line.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), !results.contains(line), line != fallback else { continue }
            results.append(line)
            if results.count == 2 { break }
        }
        return results + [fallback]
    }
    public static func imageRequest(settings: WebSearchSettings, key: String, query: String) throws -> URLRequest {
        let args = String(decoding: try JSONSerialization.data(withJSONObject: ["query": query, "limit": 8]), as: UTF8.self)
        var request = try WebSearchClient.request(settings: settings, key: key, call: .init(id: "cover", name: "web_search", arguments: args))
        let payload: [String: Any]
        switch settings.provider {
        case .firecrawl: payload = ["query": query, "limit": 12, "sources": [["type": "images"]]]
        case .exa: payload = ["query": query, "numResults": 12, "type": "auto", "contents": ["text": false, "extras": ["imageLinks": 5]]]
        case .tavily: payload = ["query": query, "max_results": 12, "search_depth": settings.advancedSearch ? "advanced" : "basic", "include_answer": false, "include_raw_content": false, "include_images": true, "include_image_descriptions": true]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload); return request
    }
    public static func catalogRequest(title: String, author: String, google: Bool) throws -> URLRequest {
        _ = try queries(title: title, author: author)
        var parts = URLComponents(string: google ? "https://www.googleapis.com/books/v1/volumes" : "https://openlibrary.org/search.json")!
        if google {
            parts.queryItems = [.init(name: "q", value: "intitle:" + title + (author.isEmpty ? "" : " inauthor:" + author)), .init(name: "maxResults", value: "20"), .init(name: "printType", value: "books")]
        } else {
            parts.queryItems = [.init(name: "title", value: title), .init(name: "limit", value: "30"), .init(name: "fields", value: "key,title,author_name,cover_i")]
            if !author.isEmpty { parts.queryItems?.append(.init(name: "author", value: author)) }
        }
        var request = URLRequest(url: parts.url!); request.timeoutInterval = 30
        request.setValue("MoRead-iOS/0.1 (+https://github.com/DataDeletionAZA/MoRead-iOS)", forHTTPHeaderField: "User-Agent")
        return request
    }
    private static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= 1_048_576, let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["error"] == nil, root["success"] as? Bool != false else { throw MoReadError.invalid("封面搜索返回了错误或无效内容。") }
        return root
    }
    private static func text(_ item: [String: Any], _ keys: [String]) -> String? {
        keys.compactMap { (item[$0] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
    }
    public static func imageURL(_ value: String) throws -> URL {
        let url = try WebSearchClient.webURL(value)
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw MoReadError.invalid("图片网址无效。") }
        parts.scheme = "https"; parts.fragment = nil
        guard let result = parts.url else { throw MoReadError.invalid("图片网址无效。") }; return result
    }
    public static func decodeImages(_ data: Data, provider: WebSearchProvider) throws -> [OnlineBookCover] {
        let root = try object(data)
        var covers: [OnlineBookCover] = [], seen = Set<String>()
        func add(_ value: Any, keys: [String] = ["url", "imageUrl", "image"], page: String? = nil, title: String? = nil) {
            let item = value as? [String: Any] ?? [:]
            guard covers.count < 30, let raw = value as? String ?? text(item, keys), let url = try? imageURL(raw), seen.insert(url.absoluteString).inserted else { return }
            let sourcePage = (page ?? text(item, ["pageUrl"])).flatMap { try? WebSearchClient.webURL($0).absoluteString } ?? url.absoluteString
            covers.append(.init(title: TextBoundary.prefix(text(item, ["title", "description"]) ?? title ?? "书籍封面", end: 240), author: "", imageURL: url.absoluteString, pageURL: sourcePage, source: provider.rawValue))
        }
        switch provider {
        case .firecrawl:
            guard let images = (root["data"] as? [String: Any])?["images"] as? [Any] ?? root["images"] as? [Any] else { throw MoReadError.invalid("图片搜索结果格式无法识别。") }
            for item in images.prefix(200) { add(item, keys: ["imageUrl", "url"], page: (item as? [String: Any])?["url"] as? String) }
        case .exa:
            guard let results = root["results"] as? [[String: Any]] else { throw MoReadError.invalid("图片搜索结果格式无法识别。") }
            for item in results.prefix(30) {
                let page = text(item, ["url", "id"]), title = text(item, ["title"])
                add(item, keys: ["image"], page: page, title: title)
                for images in [(item["extras"] as? [String: Any])?["imageLinks"] as? [Any], item["imageLinks"] as? [Any]].compactMap({ $0 }) {
                    for image in images.prefix(30) { add(image, page: page, title: title) }
                }
            }
        case .tavily:
            guard root["images"] is [Any] || root["results"] is [Any] else { throw MoReadError.invalid("图片搜索结果格式无法识别。") }
            for image in (root["images"] as? [Any] ?? []).prefix(200) { add(image) }
            for item in (root["results"] as? [[String: Any]] ?? []).prefix(30) {
                for image in (item["images"] as? [Any] ?? []).prefix(30) { add(image, page: text(item, ["url"]), title: text(item, ["title"])) }
            }
        }
        return covers
    }
    public static func decodeCatalog(_ data: Data, google: Bool, title: String) throws -> [OnlineBookCover] {
        let root = try object(data)
        var covers: [OnlineBookCover] = [], seen = Set<String>()
        if google {
            guard root["items"] is [Any] || (root["totalItems"] as? Int) == 0 else { throw MoReadError.invalid("图书目录返回格式无法识别。") }
            for item in (root["items"] as? [[String: Any]] ?? []).prefix(30) {
                guard let info = item["volumeInfo"] as? [String: Any], let links = info["imageLinks"] as? [String: Any], let raw = text(links, ["extraLarge", "large", "medium", "small", "thumbnail", "smallThumbnail"]), let url = try? imageURL(raw), seen.insert(url.absoluteString).inserted else { continue }
                let page = text(info, ["infoLink"]).flatMap { try? WebSearchClient.webURL($0).absoluteString } ?? url.absoluteString
                covers.append(.init(title: TextBoundary.prefix(text(info, ["title"]) ?? title, end: 240), author: TextBoundary.prefix((info["authors"] as? [String] ?? []).joined(separator: " / "), end: 240), imageURL: url.absoluteString, pageURL: page, source: "Google Books"))
            }
        } else {
            guard let docs = root["docs"] as? [[String: Any]] else { throw MoReadError.invalid("图书目录返回格式无法识别。") }
            for item in docs.prefix(30) {
                guard let id = try? ReaderTools.integer(item, "cover_i", range: 1...Int.max) else { continue }
                let url = "https://covers.openlibrary.org/b/id/\(id)-L.jpg?default=false"
                guard seen.insert(url).inserted else { continue }
                let path = text(item, ["key"]), page = path.flatMap { $0.hasPrefix("/works/") ? "https://openlibrary.org" + $0 : nil } ?? url
                covers.append(.init(title: TextBoundary.prefix(text(item, ["title"]) ?? title, end: 240), author: TextBoundary.prefix((item["author_name"] as? [String] ?? []).joined(separator: " / "), end: 240), imageURL: url, pageURL: (try? WebSearchClient.webURL(page).absoluteString) ?? url, source: "Open Library"))
            }
        }
        return covers
    }
    public static func search(title: String, author: String, generated: String? = nil, settings: WebSearchSettings, key: String) async throws -> BookCoverSearchResult {
        try Task.checkCancellation()
        let queries = try queries(title: title, author: author, generated: generated)
        var covers: [OnlineBookCover] = [], notices: [String] = [], seen = Set<String>()
        if settings.enabled {
            for query in queries {
                do {
                    let request = try imageRequest(settings: settings, key: key, query: query)
                    let results = try decodeImages(await fetch(request), provider: settings.provider)
                    for result in results where seen.insert(result.id).inserted { covers.append(result) }
                    if covers.count >= 24 { break }
                } catch { try Task.checkCancellation(); notices.append(settings.provider.rawValue + " 暂时无法提供图片，已尝试其他来源。"); break }
            }
        }
        let configuredResults = !covers.isEmpty
        if covers.isEmpty {
            for candidateAuthor in author.isEmpty ? [""] : [author, ""] {
                do {
                    let request = try catalogRequest(title: title, author: candidateAuthor, google: false)
                    covers = try decodeCatalog(await fetch(request), google: false, title: title)
                    if !covers.isEmpty { break }
                } catch { try Task.checkCancellation(); notices.append("Open Library 暂时无法连接。"); break }
                if !candidateAuthor.isEmpty { try await Task.sleep(for: .seconds(1)) }
            }
        }
        if covers.isEmpty {
            do { covers = try decodeCatalog(await fetch(catalogRequest(title: title, author: author, google: true)), google: true, title: title) }
            catch { try Task.checkCancellation(); notices.append("Google Books 暂时无法连接。") }
        }
        try Task.checkCancellation()
        return .init(covers: Array(covers.prefix(configuredResults ? 24 : 30)), queries: queries, notices: notices)
    }
    public static func download(_ url: String, preview: Bool = false) async throws -> Data {
        var request = URLRequest(url: try imageURL(url)); request.setValue("image/*", forHTTPHeaderField: "Accept")
        return try await fetch(request, limit: (preview ? 4 : 25) * 1024 * 1024, image: true)
    }
    private static func fetch(_ request: URLRequest, limit: Int = 1_048_576, image: Bool = false) async throws -> Data {
        try Task.checkCancellation()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 45
        let delegate: URLSessionTaskDelegate = image ? CoverImageRedirects() : NoRedirects()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), response.expectedContentLength <= limit else { throw MoReadError.invalid("封面服务暂不可用或返回内容过大。") }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { throw MoReadError.invalid("封面文件过大。") }; data.append(byte)
        }
        return data
    }
}

private final class CoverImageRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private var count = 0
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        count += 1
        guard count <= 5, let url = request.url, url.scheme?.lowercased() == "https", (try? WebSearchClient.webURL(url.absoluteString)) != nil else { completionHandler(nil); return }
        var clean = URLRequest(url: url); clean.setValue("image/*", forHTTPHeaderField: "Accept"); completionHandler(clean)
    }
}
