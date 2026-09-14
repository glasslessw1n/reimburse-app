//
//  LLMProvider.swift
//  报销整理Native
//
//  预设 LLM provider 列表（OpenAI 兼容协议）。
//  选 provider 自动填 base_url，留"自定义"给用户手输。
//

import Foundation

enum LLMProvider: String, CaseIterable, Identifiable, Sendable {
    case deepseek = "DeepSeek"
    case openai = "OpenAI"
    case moonshot = "月之暗面"
    case zhipu = "智谱"
    case ollama = "Ollama (本地)"
    case vllm = "vLLM (自部署)"
    case custom = "自定义"

    var id: String { rawValue }

    var defaultBaseURL: String {
        switch self {
        case .deepseek: return "https://api.deepseek.com/v1"
        case .openai: return "https://api.openai.com/v1"
        case .moonshot: return "https://api.moonshot.cn/v1"
        case .zhipu: return "https://open.bigmodel.cn/api/paas/v4"
        case .ollama: return "http://localhost:11434/v1"
        case .vllm: return "http://localhost:8000/v1"
        case .custom: return ""
        }
    }

    var defaultModel: String {
        switch self {
        case .deepseek: return "deepseek-chat"
        case .openai: return "gpt-4o-mini"
        case .moonshot: return "moonshot-v1-8k"
        case .zhipu: return "glm-4-flash"
        case .ollama: return "qwen2.5:14b"
        case .vllm: return "meta-llama/Meta-Llama-3-8B-Instruct"
        case .custom: return ""
        }
    }

    /// 通过 baseURL 匹配 provider（用于启动时自动识别已存的配置）
    static func match(baseURL: String) -> LLMProvider {
        let s = baseURL.lowercased()
        if s.contains("deepseek") { return .deepseek }
        if s.contains("openai.com") { return .openai }
        if s.contains("moonshot") { return .moonshot }
        if s.contains("bigmodel") || s.contains("zhipu") { return .zhipu }
        if s.contains("11434") { return .ollama }
        if s.contains(":8000") || s.contains("vllm") { return .vllm }
        return .custom
    }
}
