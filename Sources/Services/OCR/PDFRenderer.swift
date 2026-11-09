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

    /// 登机凭证在 A4 上的裁切区域 (x, y, width, height)，单位 pt（页面左上原点）
    /// 按"航旅纵横"电子登机凭证 A4 版式在原始文件上逐像素实测（2026-11-09 复核）：
    /// - 绿色横条左缘 109 / 上缘 96 / 右缘 485（绿条即裁切的左、上、右界）
    /// - 下界 326 = 右下"乘机凭证"文字下缘（实测 319.5，留少量余量）
    /// - x=109, y=96, width=376, height=230
    /// 历史教训：旧值 (78, 69, 271, 165) 是在本页约 0.718 倍的缩放预览上量得，
    /// 未换算回 pt 就写进了代码，整体缩向左上：右缘 349 把"到达地"整列裁在外面
    /// （识别只有出发地没有到达地），下缘 234 还裁掉了条码与二维码区。
    /// 量版式必须在原始尺寸上量，并与本常量交叉核对。
    static let boardingPassCrop = CGRect(x: 109, y: 96, width: 376, height: 230)

    /// 页数（供按需逐页渲染的调用方先探规模，不必整本渲染）
    static func pageCount(pdfData: Data) -> Int {
        PDFDocument(data: pdfData)?.pageCount ?? 0
    }

    /// 按需渲染单页（可裁切）：OCR 主路径用它逐页渲染、用完即弃，
    /// 不再像旧实现那样先把全部页 300 DPI 位图物化再截前几页
    /// - Parameter crop: 给非 nil 时按这个 pt 矩形在像素空间裁切（调用方只对第一页传）
    static func renderPage(pdfData: Data, pageIndex: Int, dpi: CGFloat = 300, crop: CGRect? = nil) -> CGImage? {
        guard let doc = PDFDocument(data: pdfData), let page = doc.page(at: pageIndex) else { return nil }
        let scale = dpi / 72.0
        guard var pageImage = renderPage(page, scale: scale) else { return nil }
        if let crop = crop {
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
        return pageImage
    }

    /// 渲染所有页（可裁切 boarding pass 区域）——逐页 API 的批量包装
    /// - Parameter crop: 给非 nil 时，**第一页**按这个矩形裁切；后续页不裁切
    /// - Note: 渲染策略 = 整页渲染 + CGImage.cropping(to:) 裁切
    ///         不要试图用 ctx.translateBy + page.draw 在裁切画布上画（PDFKit 会重置变换，结果白图）
    static func render(pdfData: Data, dpi: CGFloat = 300, crop: CGRect? = nil) -> [CGImage] {
        let count = pageCount(pdfData: pdfData)
        return (0..<count).compactMap { i in
            renderPage(pdfData: pdfData, pageIndex: i, dpi: dpi, crop: i == 0 ? crop : nil)
        }
    }

    /// 把单个 PDF 页面按目标 DPI 渲染成 CGImage（用 NSBitmapImageRep 精确控制像素尺寸，
    /// 避免 NSImage.lockFocus 受屏幕 backingScale 影响导致 DPI 失效/裁切错位）。
    /// 可见区域以 cropBox 为准；页面带 /Rotate 时走 PDFKit thumbnail（旋转由框架处理）。
    private static func renderPage(_ page: PDFPage, scale: CGFloat) -> CGImage? {
        let bounds = page.bounds(for: .cropBox)
        if page.rotation != 0 {
            let swap = page.rotation % 180 != 0
            let size = NSSize(
                width: max(1, (swap ? bounds.height : bounds.width) * scale),
                height: max(1, (swap ? bounds.width : bounds.height) * scale)
            )
            let thumb = page.thumbnail(of: size, for: .cropBox)
            return thumb.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        let pixelW = max(1, Int(bounds.width * scale))
        let pixelH = max(1, Int(bounds.height * scale))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelW,
            pixelsHigh: pixelH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        // rep.size 用 pt，让后续绘制坐标以 pt 计、自动按 scale 映射到像素
        rep.size = bounds.size

        NSGraphicsContext.saveGraphicsState()
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }
        NSGraphicsContext.current = ctx
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: bounds.size)).fill()
        page.draw(with: .cropBox, to: ctx.cgContext)
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    /// 只渲染第一页（低 DPI 版式探测用，避免整本渲染的内存开销）
    static func firstPageImage(pdfData: Data, dpi: CGFloat = 120) -> CGImage? {
        guard let doc = PDFDocument(data: pdfData), let page = doc.page(at: 0) else { return nil }
        return renderPage(page, scale: dpi / 72.0)
    }

    /// 检测 PDF 第一页是否为 A4 整页尺寸
    /// - A4 整页（595×842 pt）→ 未裁切的登机凭证**候选**（是否真裁切还要有登机牌证据，见 TextExtractor）
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

        // 1) 按 300 DPI 渲染整页为 CGImage（与 render() 一致；登机凭证 cropBox 与 mediaBox 一致）
        let dpi: CGFloat = 300
        let scale = dpi / 72.0
        guard let fullImage = renderPage(page, scale: scale) else { return nil }

        // 2) 裁切像素
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
