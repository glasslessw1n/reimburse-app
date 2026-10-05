//
//  LLMRecognizer.swift
//  报销整理Native
//
//  OCR 文本 → LLM → Receipt 的 orchestrator。
//  对应 core/llm_recognizer.py:recognize
//
//  两段式：先分类（短 prompt）→ 再按类型抽取（聚焦字段清单）。
//  分类失败 / 低置信 / other → 回退到单段全量（原行为），保证不比单段差。
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

        // 两段式：先分类，再按类型抽取；失败回退到单段全量
        if let type = await classify(ocrText: ocrText, filename: filename) {
            if let receipt = await extract(for: type, userMsg: userMsg, excerpt: excerpt, sourceFile: sourceFile, recognizedAt: recognizedAt) {
                return receipt
            }
        }
        return await extractFull(ocrText: ocrText, userMsg: userMsg, excerpt: excerpt, sourceFile: sourceFile, recognizedAt: recognizedAt)
    }

    // MARK: - 第一段：分类

    /// 返回确认的类型；失败 / 低置信 / other 返回 nil（交给单段全量兜底）
    private func classify(ocrText: String, filename: String) async -> BillType? {
        let userMsg = LLMPrompts.buildUserMessage(ocrText: ocrText, filename: filename)
        do {
            let raw = try await client.chatJSON(system: LLMPrompts.classifySystemPrompt, user: userMsg)
            guard let typeStr = raw["receipt_type"] as? String,
                  let type = BillType(rawValue: typeStr) else { return nil }
            let confidence = Self.doubleValue(raw["confidence"])
            guard type != .other, confidence >= 0.7 else { return nil }
            return type
        } catch {
            return nil
        }
    }

    // MARK: - 第二段：按类型抽取

    private func extract(for type: BillType, userMsg: String, excerpt: String, sourceFile: String, recognizedAt: String) async -> Receipt? {
        do {
            let raw = try await client.chatJSON(system: LLMPrompts.extractSystemPrompt(for: type), user: userMsg)
            return decode(raw, excerpt: excerpt, sourceFile: sourceFile, recognizedAt: recognizedAt)
        } catch {
            // 抽取失败 → 交给单段全量兜底
            return nil
        }
    }

    // MARK: - 单段全量（原行为，兜底）

    private func extractFull(ocrText: String, userMsg: String, excerpt: String, sourceFile: String, recognizedAt: String) async -> Receipt {
        let raw: [String: Any]
        do {
            raw = try await client.chatJSON(system: LLMPrompts.systemPrompt, user: userMsg)
        } catch {
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
        return decode(raw, excerpt: excerpt, sourceFile: sourceFile, recognizedAt: recognizedAt)
    }

    // MARK: - 解码

    private func decode(_ raw: [String: Any], excerpt: String, sourceFile: String, recognizedAt: String) -> Receipt {
        let data = (try? JSONSerialization.data(withJSONObject: raw)) ?? Data()
        do {
            var receipt = try JSONDecoder().decode(Receipt.self, from: data)
            receipt.rawTextExcerpt = excerpt
            receipt.sourceFile = sourceFile
            receipt.recognizedAt = recognizedAt
            return receipt
        } catch {
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

    /// JSON 数值 → Double（容忍数字 / 字符串）
    private static func doubleValue(_ v: Any?) -> Double {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) ?? 0 }
        return 0
    }
}

private extension ISO8601DateFormatter {
    /// 每次返回新实例，避免共享可变状态（ISO8601DateFormatter 非 Sendable）
    static var isoSeconds: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }
}
