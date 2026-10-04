//
//  PDFRenderer.swift
//  报销整理Native
//
//  PDFKit 渲染 PDF 页面为 CGImage（给 Vision OCR 用）。
//  对应 core/ocr.py:pdf_to_images
//
//  登机凭证 PDF 预处理：
//  - A4 整页（595×842 pt）→ 未裁切，渲染时按 (109, 96, 376, 230) 裁切（登机凭证区域）
//  - 单页就是凭证尺寸（~376×230 pt）→ 已裁切，渲染整页
//

import Foundation
import PDFKit
import AppKit

enum PDFRenderer {

    /// A4 页面尺寸 (pt)
    private static let a4Width: CGFloat = 595
    private static let a4Height: CGFloat = 842

    /// 登机凭证在 A4 上的裁切区域 (x, y, width, height)，单位 pt
    private static let boardingPassCrop = CGRect(x: 109, y: 96, width: 376, height: 230)

    /// 渲染所有页（可裁切 boarding pass 区域）
    /// - Parameter crop: 给非 nil 时，**第一页**按这个矩形裁切；后续页不裁切
    /// - Note: 渲染策略 = 整页渲染 + CGImage.cropping(to:) 裁切
    ///         不要试图用 ctx.translateBy + page.draw 在裁切画布上画（PDFKit 会重置变换，结果白图）
    static func render(pdfData: Data, dpi: CGFloat = 200, crop: CGRect? = nil) -> [CGImage] {
        guard let doc = PDFDocument(data: pdfData) else { return [] }
        var images: [CGImage] = []
        let scale = dpi / 72.0
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let bounds = page.bounds(for: .mediaBox)

            // 1) 先渲染整页（PDFKit 完整画一遍，不会被后续变换影响）
            let img = NSImage(size: bounds.size)
            img.lockFocus()
            NSColor.white.setFill()
            NSBezierPath(rect: NSRect(origin: .zero, size: img.size)).fill()
            page.draw(with: .mediaBox, to: NSGraphicsContext.current!.cgContext)
            img.unlockFocus()
            guard let tiff = img.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  var pageImage = rep.cgImage else { continue }

            // 2) 第一页 + 指定了 crop → 在像素空间裁切
            if i == 0, let crop = crop {
                let pixelCrop = CGRect(
                    x: crop.origin.x * scale,
                    y: crop.origin.y * scale,
                    width: crop.width * scale,
                    height: crop.height * scale
                )
                if let cropped = pageImage.cropping(to: pixelCrop) {
                    pageImage = cropped
                }
            }
            images.append(pageImage)
        }
        return images
    }

    /// 检测 PDF 是否需要登机凭证裁切
    /// - A4 整页（595×842 pt）→ 未裁切，需要裁切到 376×230
    /// - 单页尺寸 ≈ 376×230 pt → 已裁切
    /// - 其他尺寸（火车票 / 出租车票）→ 不处理
    static func needsBoardingPassCrop(pdfData: Data) -> Bool {
        guard let doc = PDFDocument(data: pdfData), doc.pageCount >= 1 else { return false }
        guard let page = doc.page(at: 0) else { return false }
        let bounds = page.bounds(for: .mediaBox)
        // A4 单页 → 未裁切
        let isA4 = abs(bounds.width - a4Width) < 5 && abs(bounds.height - a4Height) < 5
        return isA4
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
