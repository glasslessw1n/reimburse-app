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
import CryptoKit

struct LLMRecognizer {
    let client: LLMClient

    /// 识别单张票据
    func recognize(ocrText: String, filename: String = "", sourceFile: String = "") async -> Receipt {
        let recognizedAt = ISO8601DateFormatter.isoSeconds.string(from: Date())
        let excerpt = String(ocrText.prefix(500))

        // 边界：LLM 没配（本地端点允许空 Key，见 LLMConfig.isConfigured）
        guard client.config.isConfigured else {
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

        // 缓存：相同 OCR 文本（重复拖入/重跑）不重复付费调用
        let cacheKey = LLMRecognitionCache.fingerprint(ocrText: ocrText, config: client.config)
        if let cached = LLMRecognitionCache.shared.get(cacheKey) {
            var receipt = cached
            receipt.sourceFile = sourceFile
            receipt.recognizedAt = recognizedAt
            receipt.rawTextExcerpt = excerpt
            return receipt
        }

        let userMsg = LLMPrompts.buildUserMessage(ocrText: ocrText, filename: filename)

        // 两段式：先分类，再按类型抽取；失败回退到单段全量。
        // 取消必须一路终止（旧实现 catch-all 把取消吞成兜底，取消后请求照发）——
        // 各段只把 CancellationError 往上抛，这里统一转成「已取消」结果且不再发新请求。
        let result: Receipt
        do {
            if let type = try await classify(ocrText: ocrText, filename: filename) {
                if let receipt = try await extract(for: type, userMsg: userMsg, excerpt: excerpt, sourceFile: sourceFile, recognizedAt: recognizedAt) {
                    result = receipt
                } else {
                    result = try await extractFull(ocrText: ocrText, userMsg: userMsg, excerpt: excerpt, sourceFile: sourceFile, recognizedAt: recognizedAt)
                }
            } else {
                result = try await extractFull(ocrText: ocrText, userMsg: userMsg, excerpt: excerpt, sourceFile: sourceFile, recognizedAt: recognizedAt)
            }
        } catch is CancellationError {
            return Receipt(
                receiptType: .other,
                confidence: 0,
                fields: [:],
                rawTextExcerpt: excerpt,
                recognizedAt: recognizedAt,
                sourceFile: sourceFile,
                error: "识别已取消"
            )
        } catch {
            // classify/extract/extractFull 只应抛 CancellationError，其余错误已在内部兜底；
            // 真有漏网错误按 LLM 失败处理，不让整批崩
            result = Receipt(
                receiptType: .other,
                confidence: 0,
                fields: [:],
                rawTextExcerpt: excerpt,
                recognizedAt: recognizedAt,
                sourceFile: sourceFile,
                error: "LLM 调用失败：\(error.localizedDescription)"
            )
        }

        // 只缓存成功结果（失败不缓存，免得一次抖动毒化后续重跑）
        if result.error.isEmpty {
            LLMRecognitionCache.shared.set(cacheKey, receipt: result)
        }
        return result
    }

    // MARK: - 第一段：分类

    /// 返回确认的类型；失败 / 低置信 / other 返回 nil（交给单段全量兜底）
    /// - Throws: 仅 CancellationError（取消不许被兜底吞掉）
    private func classify(ocrText: String, filename: String) async throws -> BillType? {
        // 分类只发摘要（头+尾），不发全文
        let userMsg = LLMPrompts.buildClassifyMessage(ocrText: ocrText, filename: filename)
        do {
            let raw = try await client.chatJSON(system: LLMPrompts.classifySystemPrompt, user: userMsg)
            guard let typeStr = raw["receipt_type"] as? String,
                  let type = BillType(rawValue: typeStr) else { return nil }
            let confidence = Self.doubleValue(raw["confidence"])
            guard type != .other, confidence >= 0.7 else { return nil }
            return type
        } catch {
            if error is CancellationError { throw error }
            return nil
        }
    }

    // MARK: - 第二段：按类型抽取

    private func extract(for type: BillType, userMsg: String, excerpt: String, sourceFile: String, recognizedAt: String) async throws -> Receipt? {
        do {
            let raw = try await client.chatJSON(system: LLMPrompts.extractSystemPrompt(for: type), user: userMsg)
            return decode(raw, excerpt: excerpt, sourceFile: sourceFile, recognizedAt: recognizedAt)
        } catch {
            if error is CancellationError { throw error }
            // 抽取失败 → 交给单段全量兜底
            return nil
        }
    }

    // MARK: - 单段全量（原行为，兜底）

    private func extractFull(ocrText: String, userMsg: String, excerpt: String, sourceFile: String, recognizedAt: String) async throws -> Receipt {
        let raw: [String: Any]
        do {
            raw = try await client.chatJSON(system: LLMPrompts.systemPrompt, user: userMsg)
        } catch {
            if error is CancellationError { throw error }
            // 日志只记错误与配置，不写 OCR 原文（票据含姓名/票号等隐私）
            FileHandle.standardError.write(Data("""
            [LLMRecognizer] ❌ \(sourceFile) LLM 调用失败：\(error.localizedDescription)
            [LLMRecognizer]    config.baseURL=\(client.config.baseURL.absoluteString)
            [LLMRecognizer]    config.model=\(client.config.model)

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

/// LLM 识别结果缓存（进程内）：按 OCR 文本指纹 + 端点 + 模型键控。
/// 同一文件重复拖入、批量中途重跑时直接命中，不重复付费调用。
final class LLMRecognitionCache: @unchecked Sendable {
    static let shared = LLMRecognitionCache()

    private let lock = NSLock()
    private var store: [String: Receipt] = [:]
    private var order: [String] = []   // FIFO 淘汰
    private let capacity = 200

    /// 指纹：文本归一化（折叠空白）后连同端点/模型做 SHA-256
    static func fingerprint(ocrText: String, config: LLMConfig) -> String {
        let normalized = ocrText
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let raw = "\(config.baseURL.absoluteString)|\(config.model)|\(normalized)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func get(_ key: String) -> Receipt? {
        lock.lock()
        defer { lock.unlock() }
        return store[key]
    }

    func set(_ key: String, receipt: Receipt) {
        lock.lock()
        defer { lock.unlock() }
        if store[key] == nil {
            order.append(key)
            if order.count > capacity {
                let evicted = order.removeFirst(order.count - capacity)
                for k in evicted { store.removeValue(forKey: k) }
            }
        }
        store[key] = receipt
    }
}
