//
//  TextExtractor.swift
//  报销整理Native
//
//  统一入口：bytes + 文件后缀 → 文本
//  对应 core/ocr.py:extract_text_from_bytes
//
//  策略（与原 Python 一致）：
//  - PDF：先试文字层（PDFKit PDFPage.string），空就渲染图片后 OCR
//  - 图片：直接 Vision OCR
//

import Foundation

enum TextExtractor {
    enum FileKind {
        case pdf
        case image(uti: String)   // jpg/png/bmp/webp
        case unsupported

        init(suffix: String) {
            let s = suffix.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            switch s {
            case "pdf": self = .pdf
            case "jpg", "jpeg": self = .image(uti: "public.jpeg")
            case "png": self = .image(uti: "public.png")
            case "bmp": self = .image(uti: "com.microsoft.bmp")
            case "webp": self = .image(uti: "org.webmproject.webp")
            default: self = .unsupported
            }
        }
    }

    /// 主入口
    static func extract(data: Data, suffix: String, maxOCRPages: Int = 3) async throws -> String {
        let kind = FileKind(suffix: suffix)
        switch kind {
        case .pdf:
            return try await extractPDF(data: data, maxOCRPages: maxOCRPages)
        case .image:
            return try await OCRService.recognize(imageData: data)
        case .unsupported:
            throw NSError(
                domain: "TextExtractor", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "不支持的文件类型：.\(suffix)"]
            )
        }
    }

    /// 文字层是否可信：够长之外还要命中关键字段类别（金额/日期/发票号/税号等），
    /// 替代纯字符数阈值——扫描件残留的模板字（页眉页脚/水印）字数不少但没有任何关键字段。
    /// 命中 ≥2 类才采信（内部逻辑，单测覆盖）。
    static func isTrustworthyTextLayer(_ text: String) -> Bool {
        guard text.count > 100 else { return false }
        var categories = 0
        // 金额
        if text.contains("价税合计") || text.contains("金额") || text.contains("合计")
            || text.contains("¥") || text.contains("￥") { categories += 1 }
        // 日期（2026-09-10 / 2026/9/10 / 2026年9月10日）
        if text.range(of: #"\d{4}[-/年]\d{1,2}[-/月]\d{1,2}"#, options: .regularExpression) != nil { categories += 1 }
        // 发票号 / 票号
        if text.contains("发票号码") || text.contains("发票号") || text.contains("票号")
            || text.contains("No.") || text.contains("NO.") { categories += 1 }
        // 税号 / 识别号
        if text.contains("纳税人识别号") || text.contains("统一社会信用代码") || text.contains("税号") { categories += 1 }
        // 行程类关键信息（航班号/车次/入住离店）
        if text.contains("航班") || text.contains("车次") || text.contains("入住") || text.contains("离店")
            || text.contains("登机") { categories += 1 }
        return categories >= 2
    }

    /// PDF：先文字层 → 空就 OCR（最多前 maxOCRPages 页）
    /// 文字层"少"时（< 50 字符，常见于扫描 PDF 残留 "电子登机凭证" 等模板字），
    /// 也走 OCR + 登机凭证预裁切路径。
    private static func extractPDF(data: Data, maxOCRPages: Int) async throws -> String {
        // 1. 试文字层（过滤 PDF 自带的模板字）
        let text = PDFRenderer.extractText(pdfData: data)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isTrustworthyTextLayer(trimmed) {
            return trimmed
        }

        // 2. 走 OCR 路径（文字层是扫描 PDF 残留模板字 / 没文字）
        // 2a. 登机凭证裁切必须有证据才启用：旧实现只看「第一页是 A4」就裁，
        //     扫描版 A4 酒店发票/水单/增值税发票（最常见的无文字层文档）会被裁掉约八成内容。
        //     证据 = 残留文字层含登机关键词，或整页快速 OCR 探测命中关键词。
        var crop: CGRect? = nil
        if PDFRenderer.needsBoardingPassCrop(pdfData: data) {
            let keywords = ["登机", "乘机", "登机牌", "BOARDING", "Boarding"]
            if keywords.contains(where: { trimmed.contains($0) }) {
                crop = CGRect(x: 78, y: 69, width: 271, height: 165)
            } else if let probe = PDFRenderer.firstPageImage(pdfData: data, dpi: 120),
                      let probeText = try? await OCRService.recognize(cgImage: probe, level: .fast),
                      keywords.contains(where: { probeText.contains($0) }) {
                crop = CGRect(x: 78, y: 69, width: 271, height: 165)
            }
        }

        // 2b. 按需逐页渲染 + OCR（第一页用 crop 区域，其他页原样）：
        //     旧实现先把全部页 300 DPI 位图都物化再截前几页，长文档白白吃内存
        let totalPages = PDFRenderer.pageCount(pdfData: data)
        let limit = min(totalPages, maxOCRPages)
        var allText: [String] = []
        for i in 0..<limit {
            try Task.checkCancellation()
            guard let pageImage = PDFRenderer.renderPage(pdfData: data, pageIndex: i, crop: i == 0 ? crop : nil) else { continue }
            let pageText = try await OCRService.recognize(cgImage: pageImage)
            if !pageText.isEmpty {
                allText.append("--- Page \(i + 1) ---\n\(pageText)")
            }
        }
        // 超出页数上限必须留痕，不再静默丢页（LLM 与用户都能看到这份文档没识别全）
        if totalPages > maxOCRPages {
            allText.append("--- 共 \(totalPages) 页，仅识别前 \(maxOCRPages) 页，其余页未识别 ---")
        }
        return allText.joined(separator: "\n\n")
    }

    /// 是否可用（OCR 后端就绪 = Vision 框架可用；macOS 14 总是 true）
    static var isAvailable: Bool { true }
}
