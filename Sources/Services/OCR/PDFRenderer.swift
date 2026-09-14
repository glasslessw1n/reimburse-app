//
//  PDFRenderer.swift
//  报销整理Native
//
//  PDFKit 渲染 PDF 页面为 CGImage（给 Vision OCR 用）。
//  对应 core/ocr.py:pdf_to_images
//

import Foundation
import PDFKit
import AppKit

enum PDFRenderer {
    /// 把 PDF 的每一页渲染为 CGImage（dpi=200 默认；高分屏无影响，PDFKit 内部处理）
    static func render(pdfData: Data, dpi: CGFloat = 200) -> [CGImage] {
        guard let doc = PDFDocument(data: pdfData) else { return [] }
        var images: [CGImage] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            // PDFPage bounds in points; scale = dpi/72
            let scale = dpi / 72.0
            let bounds = page.bounds(for: .mediaBox)
            let pixelW = Int(bounds.width * scale)
            let pixelH = Int(bounds.height * scale)
            guard pixelW > 0, pixelH > 0 else { continue }

            // 用 NSImage 渲染（比 CGContext 直接画 page.draw 简单）
            let img = NSImage(size: NSSize(width: bounds.width, height: bounds.height))
            img.lockFocus()
            NSColor.white.setFill()
            NSBezierPath(rect: NSRect(origin: .zero, size: img.size)).fill()
            page.draw(with: .mediaBox, to: NSGraphicsContext.current!.cgContext)
            img.unlockFocus()
            if let tiff = img.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let cg = rep.cgImage {
                images.append(cg)
            }
        }
        return images
    }

    /// 直接从 PDF 提取文字层（PyMuPDF 走的是这条；优先于 OCR）
    /// 如果 PDF 是扫描版（无文字层），返回空字符串，调用方应回落到 OCR。
    static func extractText(pdfData: Data) -> String {
        guard let doc = PDFDocument(data: pdfData) else { return "" }
        var parts: [String] = []
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i), let s = page.string, !s.isEmpty {
                parts.append(s)
            }
        }
        return parts.joined(separator: "\n\n")
    }
}
