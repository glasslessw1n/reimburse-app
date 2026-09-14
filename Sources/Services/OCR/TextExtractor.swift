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

    /// PDF：先文字层 → 空就 OCR（最多前 maxOCRPages 页）
    private static func extractPDF(data: Data, maxOCRPages: Int) async throws -> String {
        // 1. 试文字层
        let text = PDFRenderer.extractText(pdfData: data)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }

        // 2. 文字层空 → 渲染图片 + OCR
        let pages = PDFRenderer.render(pdfData: data)
        let limited = Array(pages.prefix(maxOCRPages))
        var allText: [String] = []
        for (i, page) in limited.enumerated() {
            let pageText = try await OCRService.recognize(cgImage: page)
            if !pageText.isEmpty {
                allText.append("--- Page \(i + 1) ---\n\(pageText)")
            }
        }
        return allText.joined(separator: "\n\n")
    }

    /// 是否可用（OCR 后端就绪 = Vision 框架可用；macOS 14 总是 true）
    static var isAvailable: Bool { true }
}
