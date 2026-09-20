import SwiftUI
import MoReadCore

struct WebSearchSettingsView: View {
    @EnvironmentObject private var companion: CompanionModel
    @State private var search = ""
    @State private var scrape = ""
    @State private var key = ""
    @State private var hasKey = false
    @State private var status: String?
    private var policy: WebSearchSettings { companion.settings.webSearch ?? WebSearchSettings() }
    private func field<T>(_ keyPath: WritableKeyPath<WebSearchSettings, T>) -> Binding<T> {
        Binding(get: { policy[keyPath: keyPath] }, set: { value in update { $0[keyPath: keyPath] = value } })
    }
    var body: some View {
        Form {
            Section {
                Toggle("允许伴读联网", isOn: field(\.enabled)).accessibilityIdentifier("web-enabled")
                Picker("搜索服务商", selection: field(\.provider)) {
                    ForEach(WebSearchProvider.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.accessibilityIdentifier("web-provider")
            } footer: { Text("开启后，单书伴读可以按需查资料、读网页。搜索词或网址会发送给所选搜索服务，结果再提供给当前聊天模型，可能产生服务费用。网页资料不能保证避开剧情，请勿用它查询未读情节。") }
            Section("接口地址") {
                TextField("搜索接口地址", text: $search).accessibilityIdentifier("web-search-endpoint")
                TextField("网页读取接口地址", text: $scrape).accessibilityIdentifier("web-scrape-endpoint")
                Button("保存接口地址") {
                    do {
                        _ = try WebSearchClient.webURL(search, endpoint: true); _ = try WebSearchClient.webURL(scrape, endpoint: true)
                        if update({ $0.searchEndpoint = search; $0.scrapeEndpoint = scrape }) { status = "接口地址已保存。" }
                    } catch { status = error.localizedDescription }
                }
                Button("恢复官方地址") { update { $0.searchEndpoint = $0.provider.searchEndpoint; $0.scrapeEndpoint = $0.provider.scrapeEndpoint }; loadFields() }
            }.textInputAutocapitalization(.never).autocorrectionDisabled()
            Section {
                Text(hasKey ? "已保存密钥" : "尚未保存密钥").font(.caption).foregroundStyle(.secondary)
                SecureField("输入新的 API Key", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("保存密钥") { saveKey(key.trimmingCharacters(in: .whitespacesAndNewlines)) }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if hasKey { Button("删除密钥", role: .destructive) { saveKey("") } }
            } header: { Text("密钥") } footer: { Text("密钥保存在本机安全存储中，不随书库备份导出。") }
            if policy.provider == .tavily {
                Section {
                    Toggle("深入搜索", isOn: field(\.advancedSearch)).accessibilityIdentifier("web-advanced-search")
                    Toggle("深入读取网页", isOn: field(\.advancedExtract)).accessibilityIdentifier("web-advanced-extract")
                } header: { Text("Tavily 深度") } footer: { Text("关闭时使用 Basic，开启后使用 Advanced；费用按 Tavily 的计费规则计算。") }
            }
            if let status { Section { Text(status).font(.caption) } }
        }.navigationTitle("联网搜索").onAppear { loadFields() }
            .onChange(of: policy.provider) { _, _ in key = ""; status = nil; loadFields() }
    }
    @discardableResult
    private func update(_ edit: (inout WebSearchSettings) -> Void) -> Bool {
        do {
            guard let store = companion.store else { throw MoReadError.invalid("搜索设置尚未打开。") }
            var settings = companion.settings, value = policy; edit(&value); settings.webSearch = value
            try store.save(settings); companion.stop(); companion.settings = settings; return true
        } catch { status = error.localizedDescription; return false }
    }
    private func loadFields() {
        search = policy.searchEndpoint; scrape = policy.scrapeEndpoint
        do { hasKey = try !KeychainStore.read(policy.provider.credentialID).isEmpty } catch { status = error.localizedDescription }
    }
    private func saveKey(_ value: String) {
        do { try KeychainStore.save(value, for: policy.provider.credentialID); companion.stop(); key = ""; hasKey = !value.isEmpty; status = value.isEmpty ? "密钥已删除。" : "密钥已保存。" }
        catch { status = error.localizedDescription }
    }
}

extension CompanionModel {
    func runWebTool(_ call: ChatToolCall, policy: WebSearchSettings) async throws -> String {
        #if DEBUG
        if simulatedTools && ProcessInfo.processInfo.arguments.contains("--simulate-web") {
            _ = try WebSearchClient.request(settings: policy, key: "local-test", call: call)
            try await Task.sleep(for: .milliseconds(100))
            if call.arguments.contains("unavailable") { throw MoReadError.invalid("搜索服务暂不可用。") }
            let scrape = call.name == "web_scrape"
            let entry: [String: Any] = ["title": "灯塔资料", "url": "https://example.invalid/lighthouse", "description": "A lighthouse guides ships.", "text": "A lighthouse guides ships.", "content": "A lighthouse guides ships.", "markdown": "Lighthouse keepers maintained the light.", "raw_content": "Lighthouse keepers maintained the light."]
            let body: [String: Any]
            if policy.provider == .firecrawl { body = scrape ? ["data": entry] : ["data": ["web": [entry]]] }
            else { body = ["results": [entry]] }
            return try WebSearchClient.decode(JSONSerialization.data(withJSONObject: body), provider: policy.provider, call: call).encoded()
        }
        #endif
        let key = try KeychainStore.read(policy.provider.credentialID)
        return try await WebSearchClient.run(settings: policy, key: key, call: call).encoded()
    }
}
