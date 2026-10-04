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

    /// 生成登机凭证的"裁切版 PDF Data"
    /// - 若 PDF 是 A4 整页未裁切 → 只保留 boardingPassCrop 区域，输出单页 PDF（376×230 pt）
    /// - 若 PDF 已是凭证尺寸 → 原样返回
    /// - 失败 → 返回 nil
    static func cropBoardingPass(pdfData: Data) -> Data? {
        guard let doc = PDFDocument(data: pdfData), doc.pageCount >= 1,
              let page = doc.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        let isA4 = abs(bounds.width - a4Width) < 5 && abs(bounds.height - a4Height) < 5
        if !isA4 { return pdfData }   // 已经是凭证尺寸 → 不动

        // 策略：复制原 page，调小 mediaBox 为 crop，再叠加 translation 让内容落到新 box 原点
        // PDFKit 没有直接的 transform setter，但 page.copy() 返回新 page，
        // 设置 setBounds(.mediaBox) + setBounds(.cropBox) + setRotation 仍带原坐标系
        // 最稳的办法：render 为 image，再嵌进新 PDF（保留文字层不可行）
        // 这里采用 NSImage 渲染 → 嵌入新 PDF。文件会大一点（不再有矢量文字层），
        // 但 376×230 凭证区域的 image 也只有 ~50KB，可以接受。

        let crop = boardingPassCrop
        let pageBounds = page.bounds(for: .mediaBox)

        // 1) 渲染原 page 的 crop 区域为 CGImage
        let dpi: CGFloat = 200
        let scale = dpi / 72.0
        let cropSize = CGSize(width: crop.width * scale, height: crop.height * scale)
        let img = NSImage(size: pageBounds.size)
        img.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: img.size)).fill()
        page.draw(with: .mediaBox, to: NSGraphicsContext.current!.cgContext)
        img.unlockFocus()
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let fullImage = rep.cgImage else { return nil }

        // 2) 裁切像素
        // 与 PDFRenderer.render 的 crop 保持一致：直接 crop.origin.y * scale，不反转
        let pixelCrop = CGRect(
            x: crop.origin.x * scale,
            y: crop.origin.y * scale,
            width: crop.width * scale,
            height: crop.height * scale
        )
        guard let croppedImage = fullImage.cropping(to: pixelCrop) else { return nil }

        // 3) 把 croppedImage 嵌进新 PDF（mediaBox = crop 区域）
        let mutableData = NSMutableData()
        guard let consumer = CGDataConsumer(data: mutableData as CFMutableData) else { return nil }
        var mediaBox = CGRect(origin: .zero, size: crop.size)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        ctx.beginPDFPage(nil)
        ctx.draw(croppedImage, in: CGRect(origin: .zero, size: crop.size))
        ctx.endPDFPage()
        ctx.closePDF()

        return mutableData as Data
    }
}
