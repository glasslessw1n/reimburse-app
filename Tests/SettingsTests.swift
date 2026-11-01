//
//  SettingsTests.swift
//  四期：.env 合并逻辑（Keychain 迁移后 .env 只留非敏感配置、未知键保留）
//

import Testing
import Foundation
@testable import 报销整理

@MainActor
struct SettingsTests {

    private func settings(
        apiKey: String = "sk-secret",
        model: String = "deepseek-chat",
        buyerName: String = ""
    ) -> LLMSettings {
        var s = LLMSettings()
        s.apiKey = apiKey
        s.baseURL = URL(string: "https://api.deepseek.com/v1")!
        s.model = model
        s.buyerName = buyerName
        return s
    }

    @Test func envMergeRemovesPlaintextKey() {
        let existing = """
        # 我的配置
        LLM_API_KEY=sk-old-secret
        LLM_MODEL=old-model
        """
        let merged = LLMSettingsStore.mergedEnvContent(existing: existing, settings: settings())
        #expect(!merged.contains("sk-old-secret"))
        #expect(!merged.contains("LLM_API_KEY"))
    }

    @Test func envMergePreservesUnknownKeysAndComments() {
        let existing = """
        # 我的配置
        CUSTOM_FLAG=on
        LLM_MODEL=old-model
        # 尾部注释
        """
        let merged = LLMSettingsStore.mergedEnvContent(existing: existing, settings: settings())
        #expect(merged.contains("CUSTOM_FLAG=on"))
        #expect(merged.contains("# 尾部注释"))
        #expect(merged.contains("LLM_MODEL=deepseek-chat"))
        // 已知键就地更新，不在文件末尾再追加一份
        #expect(merged.components(separatedBy: "LLM_MODEL=").count == 2)
    }

    @Test func envMergeDropsEmptyOptionalKeys() {
        let existing = "BUYER_NAME=旧公司\nLLM_MODEL=m\n"
        let merged = LLMSettingsStore.mergedEnvContent(existing: existing, settings: settings(buyerName: ""))
        #expect(!merged.contains("BUYER_NAME"))
        let merged2 = LLMSettingsStore.mergedEnvContent(existing: existing, settings: settings(buyerName: "医科达"))
        #expect(merged2.contains("BUYER_NAME=医科达"))
    }

    @Test func envMergeFromEmptyFile() {
        let merged = LLMSettingsStore.mergedEnvContent(existing: "", settings: settings())
        #expect(merged.contains("LLM_BASE_URL=https://api.deepseek.com/v1"))
        #expect(merged.contains("LLM_MODEL=deepseek-chat"))
        #expect(!merged.contains("LLM_API_KEY"))
    }
}
