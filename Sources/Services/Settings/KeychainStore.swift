//
//  KeychainStore.swift
//  报销整理Native
//
//  极简 Keychain 泛型密码存储（只存 LLM API Key 一项）。
//  替代旧实现把 Key 明文写进 .env 的做法；.env 从此只放非敏感配置。
//

import Foundation
import Security

enum KeychainError: LocalizedError {
    case status(OSStatus)
    var errorDescription: String? {
        switch self {
        case .status(let s):
            return "Keychain 操作失败（OSStatus \(s)）"
        }
    }
}

enum KeychainStore {
    /// LLM API Key 的条目账号名
    static let apiKeyAccount = "llm-api-key"

    private static var service: String {
        Bundle.main.bundleIdentifier ?? "com.local.reimbursement"
    }

    static func get(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(account: account)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let status = SecItemAdd(addQuery as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError.status(status) }
            return
        }
        throw KeychainError.status(updateStatus)
    }

    static func delete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
