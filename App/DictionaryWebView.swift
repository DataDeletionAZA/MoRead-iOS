import SwiftUI
import WebKit
import UniformTypeIdentifiers
import MoReadCore

struct DictionaryWebView: UIViewRepresentable {
    let entry: DictionaryDefinition
    let library: LocalDictionaries
    @Binding var position: CGPoint
    @Binding var plainText: String
    @Binding var error: String?
    let onLookup: (String) -> Void
    @Environment(\.colorScheme) private var colorScheme
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.setURLSchemeHandler(context.coordinator, forURLScheme: "moread-dictionary")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator; view.scrollView.delegate = context.coordinator
        view.isOpaque = false; view.backgroundColor = .clear
        view.accessibilityIdentifier = "dictionary-definition"
        let coordinator = context.coordinator
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "MoReadDictionaryLocalOnly-v1", encodedContentRuleList: """
        [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}}]
        """) { [weak view, weak coordinator] rules, error in
            guard let view, let coordinator, coordinator.active else { return }
            guard let rules else { coordinator.parent.error = "无法准备本地词典页面，请重新查询。"; return }
            view.configuration.userContentController.add(rules)
            coordinator.ready = true
            view.load(URLRequest(url: coordinator.url, cachePolicy: .reloadIgnoringLocalCacheData))
        }
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        let dark = colorScheme == .dark
        if coordinator.dark != dark {
            coordinator.dark = dark; coordinator.restoring = true
            if coordinator.ready { view.load(URLRequest(url: coordinator.url, cachePolicy: .reloadIgnoringLocalCacheData)) }
        }
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.active = false
        view.stopLoading(); view.navigationDelegate = nil; view.scrollView.delegate = nil
        for task in coordinator.tasks.values { task.cancel() }; coordinator.tasks.removeAll()
    }
    final class Coordinator: NSObject, WKURLSchemeHandler, WKNavigationDelegate, UIScrollViewDelegate {
        var parent: DictionaryWebView
        var dark: Bool?
        var restoring = true
        var active = true
        var ready = false
        var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
        var url: URL { URL(string: "moread-dictionary://\(parent.entry.id.uuidString.lowercased())/entry.html")! }
        init(_ parent: DictionaryWebView) { self.parent = parent }
        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            let key = ObjectIdentifier(urlSchemeTask)
            tasks[key] = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { tasks[key] = nil }
                do {
                    guard let requested = urlSchemeTask.request.url, requested.scheme == url.scheme, requested.host == url.host else { throw URLError(.unsupportedURL) }
                    let main = requested.path == "/entry.html"
                    let data: Data
                    if main {
                        let text = dark == true ? "#dedede" : "#242424", background = dark == true ? "#202020" : "#fafafa"
                        let html = """
                        <!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src moread-dictionary: data:; style-src 'unsafe-inline' moread-dictionary:; font-src moread-dictionary:; media-src moread-dictionary:; base-uri 'none'; form-action 'none';"><meta name="viewport" content="width=device-width,initial-scale=1"><style>body{margin:16px;font:17px/1.65 -apple-system;overflow-wrap:anywhere;color:\(text);background:\(background)}img{max-width:100%;height:auto}table{max-width:100%}a{color:#527bc0}</style></head><body>\(parent.entry.html)\(dark == true ? "<style>html,body{background:#202020!important;color:#dedede!important}body *{color:inherit!important;background-color:transparent!important}a{color:#b8cfff!important}</style>" : "")</body></html>
                        """
                        data = Data(html.utf8)
                    } else {
                        guard let bytes = try await parent.library.resource(parent.entry.id, path: requested.path) else { throw URLError(.fileDoesNotExist) }
                        data = bytes
                    }
                    try Task.checkCancellation()
                    guard tasks[key] != nil else { return }
                    let mime = main ? "text/html" : UTType(filenameExtension: requested.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                    urlSchemeTask.didReceive(URLResponse(url: requested, mimeType: mime, expectedContentLength: data.count, textEncodingName: ["text/html", "text/css", "image/svg+xml"].contains(mime) ? "utf-8" : nil))
                    urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
                } catch { if !Task.isCancelled, tasks[key] != nil { urlSchemeTask.didFailWithError(error) } }
            }
        }
        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) { tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel() }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let target = navigationAction.request.url else { decisionHandler(.cancel); return }
            if target.scheme == "entry", navigationAction.navigationType == .linkActivated {
                let raw = target.absoluteString.dropFirst("entry://".count).split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
                let word = raw.removingPercentEncoding ?? raw
                if !word.isEmpty, word.count <= 80 { parent.onLookup(word) }
                decisionHandler(.cancel)
            } else { decisionHandler(target.scheme == url.scheme && target.host == url.host && target.path == url.path && navigationAction.targetFrame?.isMainFrame == true ? .allow : .cancel) }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.scrollView.setContentOffset(parent.position, animated: false); restoring = false
            let script = """
            (() => { const rows = [], walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT); let node;
            while (node = walker.nextNode()) { if (!node.parentElement.closest('script,style,noscript,iframe,object,template') && node.nodeValue.trim()) rows.push(node.nodeValue.trim()); }
            return rows.join('\\n'); })()
            """
            webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { [weak self] result in
                guard let self, active, case .success(let value) = result, let text = value as? String else { return }
                parent.plainText = text
            }
        }
        func scrollViewDidScroll(_ scrollView: UIScrollView) { if !restoring { parent.position = scrollView.contentOffset } }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { parent.error = "词典排版加载失败：" + error.localizedDescription }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { parent.error = "词典排版已中断，请重新查询。" }
    }
}
