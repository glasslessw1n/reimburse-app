//
//  LLMClient.swift
//  报销整理Native
//
//  OpenAI 兼容协议 LLM 客户端（URLSession）。
//  对应 core/llm_client.py:call_llm_json / test_connection / list_models。
//
//  支持 OpenAI / DeepSeek / 月之暗面 / 智谱 / Ollama / vLLM 等
//  任何 OpenAI Chat Completions 兼容服务。
//

import Foundation

struct LLMConfig {
    var apiKey: String
    var baseURL: URL        // e.g. https://api.deepseek.com/v1
    var model: String       // e.g. deepseek-chat
    var timeout: TimeInterval

    static let `default` = LLMConfig(
        apiKey: "",
        baseURL: URL(string: "https://api.openai.com/v1")!,
        model: "gpt-4o-mini",
        timeout: 60
    )
}

enum LLMError: LocalizedError {
    case notConfigured
    case http(Int, String)
    case invalidResponse
    case parseFailed(String)
    case allRetriesFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "未配置 LLM API Key"
        case .http(let code, let body): return "HTTP \(code): \(body.prefix(200))"
        case .invalidResponse: return "响应格式无效"
        case .parseFailed(let s): return "JSON 解析失败：\(s.prefix(200))"
        case .allRetriesFailed(let s): return "LLM 调用失败：\(s)"
        }
    }
}

/// OpenAI Chat Completions 兼容协议请求体
private struct ChatRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }
    let model: String
    let messages: [Message]
    let temperature: Double
    let response_format: [String: String]?
}

private struct ChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let role: String
            let content: String
        }
        let message: Message
    }
    let choices: [Choice]
}

struct LLMClient {
    let config: LLMConfig

    init(config: LLMConfig) {
        self.config = config
    }

    /// 主入口：发 system + user → 拿 content string
    /// - Parameters:
    ///   - useJSONFormat: 是否请求 JSON 模式（OpenAI 要求 prompt 含 "json" 字样）
    /// - Note: 当 useJSONFormat=true 且 system prompt 不含 "json" 时，自动追加提示；
    ///         若服务端仍 400，自动回退到不带 response_format 重试。
    func chat(system: String, user: String, temperature: Double = 0.0, useJSONFormat: Bool = true) async throws -> String {
        guard !config.apiKey.isEmpty else { throw LLMError.notConfigured }

        let url = config.baseURL.appendingPathComponent("chat/completions")

        // 第一次尝试：可能带 JSON 模式
        var systemForJSON = system
        if useJSONFormat && !system.localizedCaseInsensitiveContains("json") {
            // OpenAI response_format=json_object 的硬性要求
            systemForJSON += "\n\n请以合法 JSON 输出你的响应。"
        }

        var attempt = 0
        let maxAttempts = useJSONFormat ? 2 : 1
        var lastError: Error?

        while attempt < maxAttempts {
            attempt += 1
            let useFormatThisTime = useJSONFormat && attempt == 1

            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = config.timeout
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")

            let body = ChatRequest(
                model: config.model,
                messages: [
                    .init(role: "system", content: useFormatThisTime ? systemForJSON : system),
                    .init(role: "user", content: user)
                ],
                temperature: temperature,
                response_format: useFormatThisTime ? ["type": "json_object"] : nil
            )
            req.httpBody = try JSONEncoder().encode(body)

            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw LLMError.invalidResponse }

            if (200..<300).contains(http.statusCode) {
                do {
                    let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
                    guard let content = decoded.choices.first?.message.content else {
                        throw LLMError.invalidResponse
                    }
                    return content
                } catch {
                    throw LLMError.parseFailed(String(data: data, encoding: .utf8) ?? "")
                }
            }

            // 失败：JSON 模式 400 → 回退一次（不带 response_format）
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            lastError = LLMError.http(http.statusCode, bodyStr)
            if useFormatThisTime && http.statusCode == 400 {
                continue
            }
            throw LLMError.http(http.statusCode, bodyStr)
        }

        throw lastError ?? LLMError.invalidResponse
    }

    /// 调 LLM 拿 JSON dict（自动剥 markdown 代码块）
    func chatJSON(system: String, user: String, maxRetries: Int = 2) async throws -> [String: Any] {
        var lastError: Error?
        for attempt in 0...maxRetries {
            do {
                let content = try await chat(system: system, user: user)
                return try JSONParser.extractFirstJSONObject(from: content)
            } catch {
                lastError = error
                if attempt < maxRetries {
                    try? await Task.sleep(nanoseconds: UInt64(1_500_000_000 * (attempt + 1)))
                }
            }
        }
        throw LLMError.allRetriesFailed(lastError?.localizedDescription ?? "unknown")
    }

    /// 测试连接 + 拉模型列表
    func listModels() async throws -> [String] {
        let url = config.baseURL.appendingPathComponent("models")
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.http(code, body)
        }
        // 响应 { "data": [{ "id": "..." }, ...] }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["data"] as? [[String: Any]] else {
            return []
        }
        return arr.compactMap { $0["id"] as? String }
    }
}

/// JSON 解析工具（对应 core/llm_client.py:_parse_json / _extract_first_json_object）
enum JSONParser {
    /// 提取首个 JSON 对象（容忍 markdown 代码块、文字包裹）
    static func extractFirstJSONObject(from text: String) throws -> [String: Any] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. 直接尝试
        if let data = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }

        // 2. 剥离 markdown ```json ... ```
        if let range = trimmed.range(of: "```"),
           let endRange = trimmed[range.upperBound...].range(of: "```") {
            let inner = trimmed[range.upperBound..<endRange.lowerBound]
                .trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
                .replacingOccurrences(of: "json", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = inner.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return obj
            }
        }

        // 3. 找第一个 { 到匹配 }
        if let start = trimmed.firstIndex(of: "{") {
            var depth = 0
            var end: String.Index?
            for i in trimmed[start...].indices {
                let ch = trimmed[i]
                if ch == "{" { depth += 1 }
                else if ch == "}" {
                    depth -= 1
                    if depth == 0 { end = i; break }
                }
            }
            if let endIdx = end {
                let candidate = String(trimmed[start...endIdx])
                if let data = candidate.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    return obj
                }
            }
        }

        throw LLMError.parseFailed(text)
    }
}
