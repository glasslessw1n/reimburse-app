//
//  PipelineTests.swift
//  三期：prompt 截断 / 识别缓存指纹 / 文字层可信判定
//

import Testing
import Foundation
@testable import 报销整理

struct PipelineTests {

    // MARK: - OCR 文本截断（头尾保留）

    @Test func cappedTextKeepsShortText() {
        let s = String(repeating: "票", count: 100)
        #expect(LLMPrompts.cappedText(s, limit: 6000) == s)
    }

    @Test func cappedTextKeepsHeadAndTail() {
        let head = String(repeating: "头", count: 5000)
        let tail = String(repeating: "尾", count: 5000)
        let capped = LLMPrompts.cappedText(head + tail, limit: 600)
        #expect(capped.hasPrefix(String(repeating: "头", count: 400)))
        #expect(capped.hasSuffix(String(repeating: "尾", count: 200)))
        #expect(capped.contains("已省略"))
    }

    @Test func classifyMessageIsShorterThanFullMessage() {
        let text = String(repeating: "某酒店发票金额 100 元 ", count: 500)
        let classify = LLMPrompts.buildClassifyMessage(ocrText: text, filename: "a.pdf")
        let full = LLMPrompts.buildUserMessage(ocrText: text, filename: "a.pdf")
        #expect(classify.count < full.count)
    }

    // MARK: - 缓存指纹

    @Test func fingerprintStableAcrossWhitespaceVariants() {
        let config = LLMConfig(apiKey: "k", baseURL: URL(string: "https://api.deepseek.com/v1")!, model: "m", timeout: 60)
        let a = LLMRecognitionCache.fingerprint(ocrText: "发票 金额 100\n日期 2026-09-10", config: config)
        let b = LLMRecognitionCache.fingerprint(ocrText: "发票  金额   100  日期 2026-09-10 ", config: config)
        #expect(a == b)
        var other = config
        other.model = "another-model"
        #expect(LLMRecognitionCache.fingerprint(ocrText: "发票 金额 100", config: other) !=
                LLMRecognitionCache.fingerprint(ocrText: "发票 金额 100", config: config))
    }

    // MARK: - 文字层可信判定

    @Test func textLayerWithKeyFieldsIsTrusted() {
        let text = String(repeating: "电子发票（普通发票） 发票号码：12345678901234567890 ", count: 3)
            + "开票日期：2026年09月10日 价税合计 ¥553.00 纳税人识别号：91310000XXXXXXXXXX"
        #expect(TextExtractor.isTrustworthyTextLayer(text))
    }

    @Test func templateOnlyTextLayerIsNotTrusted() {
        // 扫描件残留模板字：字数不少，但没有金额/日期/票号/税号任何关键字段
        let text = String(repeating: "电子登机凭证 行程提示 请提前到达机场办理乘机手续 感谢您的配合 ", count: 4)
        #expect(!TextExtractor.isTrustworthyTextLayer(text))
    }

    @Test func shortTextLayerIsNotTrusted() {
        let text = "价税合计 ¥100.00 2026-09-10"
        #expect(!TextExtractor.isTrustworthyTextLayer(text))
    }
}
