import Foundation
import Security
import MoReadCore

enum KeychainStore {
    private static let service = "io.github.datadeletionaza.MoRead.providers"
    static func readAsync(_ id: UUID) async throws -> String {
        let work = Task.detached(priority: .userInitiated) {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--simulate-slow-credentials") { try await Task.sleep(for: .seconds(30)) }
            if ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--simulate-unavailable-credentials") { throw MoReadError.invalid("系统安全存储暂不可用。") }
            #endif
            try Task.checkCancellation()
            return try read(id)
        }
        let value = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        try Task.checkCancellation()
        return value
    }
    static func read(_ id: UUID) throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: id.uuidString, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw MoReadError.invalid("无法读取密钥，请解锁设备后重试。") }
        return value
    }
    static func save(_ value: String, for id: UUID) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw MoReadError.invalid("无法删除密钥。") }
            return
        }
        let update = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(value.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw MoReadError.invalid("无法保存密钥。") }
        } else if status != errSecSuccess { throw MoReadError.invalid("无法更新密钥。") }
    }
}
