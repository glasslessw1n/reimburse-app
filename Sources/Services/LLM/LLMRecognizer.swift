//
//  LLMRecognizer.swift
//  报销整理Native
//
//  OCR 文本 → LLM → Receipt 的 orchestrator。
//  对应 core/llm_recognizer.py:recognize
//
//  失败兜底（不抛异常）：返回 receipt_type=other + confidence=0 + error 填原因
//

import Foundation

struct LLMRecognizer {
    let client: LLMClient

    /// 识别单张票据
    func recognize(ocrText: String, filename: String = "", sourceFile: String = "") async -> Receipt {
        let recognizedAt = ISO8601DateFormatter.isoSeconds.string(from: Date())
        let excerpt = String(ocrText.prefix(500))

        // 边界：LLM 没配
        guard !client.config.apiKey.isEmpty else {
            return Receipt(
                receiptType: .other,
                confidence: 0,
                fields: [:],
                rawTextExcerpt: excerpt,
                recognizedAt: recognizedAt,
                sourceFile: sourceFile,
                error: "未配置 LLM API Key"
            )
        }

        // 边界：OCR 文本完全空且没文件名
        if ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && filename.isEmpty {
            return Receipt(
                receiptType: .other,
                confidence: 0,
                fields: [:],
                rawTextExcerpt: "",
                recognizedAt: recognizedAt,
                sourceFile: sourceFile,
                error: "OCR 文本为空且无文件名"
            )
        }

        let userMsg = LLMPrompts.buildUserMessage(ocrText: ocrText, filename: filename)
        let raw: [String: Any]
        do {
            raw = try await client.chatJSON(system: LLMPrompts.systemPrompt, user: userMsg)
        } catch {
            // 诊断：把 LLM 实际响应打出来
            FileHandle.standardError.write(Data("""
            [LLMRecognizer] ❌ \(sourceFile) LLM 调用失败：\(error.localizedDescription)
            [LLMRecognizer]    config.baseURL=\(client.config.baseURL.absoluteString)
            [LLMRecognizer]    config.model=\(client.config.model)
            [LLMRecognizer]    ocrText 前 200 字：\(String(ocrText.prefix(200)))

            """.utf8))
            return Receipt(
                receiptType: .other,
                confidence: 0,
                fields: [:],
                rawTextExcerpt: excerpt,
                recognizedAt: recognizedAt,
                sourceFile: sourceFile,
                error: "LLM 调用失败：\(error.localizedDescription)"
            )
        }

        // raw 是 dict；用 JSONSerialization 转成 Data 再 decode 给 Receipt
        let data = (try? JSONSerialization.data(withJSONObject: raw)) ?? Data()
        do {
            var receipt = try JSONDecoder().decode(Receipt.self, from: data)
            receipt.rawTextExcerpt = excerpt
            receipt.sourceFile = sourceFile
            receipt.recognizedAt = recognizedAt
            return receipt
        } catch {
            // 诊断：把原始 JSON 打出来
            let rawJSON = (try? JSONSerialization.data(withJSONObject: raw, options: .prettyPrinted))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "(无法序列化)"
            FileHandle.standardError.write(Data("""
            [LLMRecognizer] ❌ \(sourceFile) Receipt 解析失败：\(error.localizedDescription)
            [LLMRecognizer]    原始 JSON：
            \(rawJSON.prefix(800))

            """.utf8))
            return Receipt(
                receiptType: .other,
                confidence: 0,
                fields: [:],
                rawTextExcerpt: excerpt,
                recognizedAt: recognizedAt,
                sourceFile: sourceFile,
                error: "Receipt 解析失败：\(error.localizedDescription)"
            )
        }
    }
}

private extension ISO8601DateFormatter {
    static let isoSeconds: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
