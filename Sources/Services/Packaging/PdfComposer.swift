//
//  PdfComposer.swift
//  报销整理Native
//
//  整合 PDF：把一个会话的全部票据按打印排版规则排进 A4 页面（矢量贴页，不光栅化）。
//  规则源自 reimburse-toolkit 的 compose.py 并按实际报销口径修订：
//
//  每个行程的组装顺序：
//    自驾行程单（整页）→ 加油/通行费（发票类分档排版）→ 行程证明页 P1（最早+最晚交通票 1×2）
//    → 交通票 3×2（登机牌不进：只是行程证明，只上证明页且只用起止两张，其余弃用）
//    → 酒店（水单整页后紧跟其配对发票同页两份）→ 滴滴行程单 → 滴滴发票 → 餐饮 → 其他
//  本地段：通信（1×2）→ 滴滴行程单 → 滴滴发票 → 餐饮 → 其他。
//
//  发票类分档排版（滴滴发票 / 餐饮 / 加油通行费 / 其他，四类同规，均为左转 90°）：
//    1 张 → 不拼版，旋转后整页；2 张 → 旋转后 1×2；≥3 张 → 旋转后 2×2。
//

import Foundation
import PDFKit
import AppKit

/// 一张源页面（可选带内容裁切框，坐标为源页面空间）
struct SourcePage {
    var page: PDFPage
    var crop: CGRect? = nil
}

enum PdfComposer {

    enum ComposeError: LocalizedError {
        case noBills
        case sourceMissing(String)
        var errorDescription: String? {
            switch self {
            case .noBills: return "没有可排版的票据"
            case .sourceMissing(let f): return "原文件缺失：\(f)"
            }
        }
    }

    // A4 纵向（pt）与版式常量
    static let pageW: CGFloat = 595.28
    static let pageH: CGFloat = 841.89
    static let margin: CGFloat = 20
    static let gap: CGFloat = 8

    /// 组成整合 PDF 并返回数据
    static func compose(trips: [TripGroup], local: [BillInfo], originalsDir: URL) throws -> Data {
        let loader = SourceLoader(originalsDir: originalsDir)
        var pages: [ComposedPage] = []

        for trip in trips {
            try composeGroup(bills: trip.bills, isLocal: false, loader: loader, into: &pages)
        }
        if !local.isEmpty {
            try composeGroup(bills: local, isLocal: true, loader: loader, into: &pages)
        }
        guard !pages.isEmpty else { throw ComposeError.noBills }

        let doc = PDFDocument()
        for (i, p) in pages.enumerated() { doc.insert(p, at: i) }
        guard let data = doc.dataRepresentation() else { throw ComposeError.noBills }
        return data
    }

    // MARK: - 分组排版

    private static func composeGroup(
        bills: [BillInfo], isLocal: Bool, loader: SourceLoader, into pages: inout [ComposedPage]
    ) throws {
        let byDate: (BillInfo, BillInfo) -> Bool = { ($0.dateRange.start, $0.sourceFile) < ($1.dateRange.start, $1.sourceFile) }
        let transport = bills.filter { [.trainTicket, .flightItinerary, .boardingPass].contains($0.billType) }.sorted(by: byDate)
        let selfDrive = bills.filter { $0.billType == .selfDriveSheet }.sorted(by: byDate)
        let gasToll = bills.filter { $0.billType == .gasInvoice || $0.billType == .tollInvoice }.sorted(by: byDate)
        let folios = bills.filter { $0.billType == .hotelFolio }.sorted(by: byDate)
        let hotelInvoices = bills.filter { $0.billType == .hotelInvoice }.sorted(by: byDate)
        let didiTrips = bills.filter { $0.billType == .didiTrip }.sorted { $0.didiLetter < $1.didiLetter }
        let didiInvoices = bills.filter { $0.billType == .didiInvoice }.sorted { $0.didiLetter < $1.didiLetter }
        let dining = bills.filter { $0.billType == .dining }.sorted(by: byDate)
        let telecom = bills.filter { $0.billType == .telecom }.sorted(by: byDate)
        let handled: Set<BillType> = [.trainTicket, .flightItinerary, .boardingPass, .selfDriveSheet,
                                      .gasInvoice, .tollInvoice, .hotelFolio, .hotelInvoice,
                                      .didiTrip, .didiInvoice, .dining, .telecom]
        let other = bills.filter { !handled.contains($0.billType) }.sorted(by: byDate)

        if isLocal {
            // 本地段：通信 1×2 → 滴滴 → 餐饮/其他（发票类分档）→ 本地酒店发票归其他兜底
            try grid(bills: telecom, rows: 1, cols: 2, rotate: false, loader: loader, into: &pages)
            try didiSection(trips: didiTrips, invoices: didiInvoices, loader: loader, into: &pages)
            try invoiceGrid(bills: dining, loader: loader, into: &pages)
            try invoiceGrid(bills: other + hotelInvoices, loader: loader, into: &pages)
            return
        }

        // 1. 自驾行程单：整页
        for b in selfDrive {
            for p in try loader.pages(of: b) { fullPage(p, into: &pages) }
        }
        // 2. 加油 + 通行费：发票类分档排版
        try invoiceGrid(bills: gasToll, loader: loader, into: &pages)
        // 3. 行程证明页 P1：最早 + 最晚交通票各一（孤张也进，保证不丢）
        if !transport.isEmpty {
            var proof: [SourcePage] = []
            if let first = try loader.pages(of: transport[0]).first {
                proof.append(first)
            }
            if transport.count > 1, let last = try loader.pages(of: transport[transport.count - 1]).first {
                proof.append(last)
            }
            gridPages(proof, rows: 2, cols: 1, rotate: false, into: &pages)
        }
        // 4. 交通票 3×2：登机牌一律不进——它们只是行程证明，只出现在证明页；
        //    超过两张时只有起止两张上证明页，其余在整合 PDF 中弃用（原文件仍在 ZIP 里）。
        //    火车票/行程单等报销凭证以及出租车/滴滴等打车凭证照常排。
        let transportGrid = transport.filter { $0.billType != .boardingPass }
        try grid(bills: transportGrid, rows: 3, cols: 2, rotate: false, loader: loader, into: &pages)
        // 5. 酒店：每张水单整页后紧跟它配对的发票（同页两份）；未配对发票排在本组末尾
        var usedInvoiceUIDs = Set<String>()
        for folio in folios {
            for p in try loader.pages(of: folio) { fullPage(p, into: &pages) }
            if let inv = hotelInvoices.first(where: { $0.pairedFolioUID == folio.uid }) {
                usedInvoiceUIDs.insert(inv.uid)
                try placeHotelInvoice(inv, loader: loader, into: &pages)
            }
        }
        for inv in hotelInvoices where !usedInvoiceUIDs.contains(inv.uid) {
            try placeHotelInvoice(inv, loader: loader, into: &pages)
        }
        // 6/7. 滴滴
        try didiSection(trips: didiTrips, invoices: didiInvoices, loader: loader, into: &pages)
        // 8. 餐饮：发票类分档排版
        try invoiceGrid(bills: dining, loader: loader, into: &pages)
        // 9. 其他：发票类分档排版兜底（任何类型都不丢）
        try invoiceGrid(bills: other, loader: loader, into: &pages)
    }

    /// 酒店发票：首页同页排两份，其余页整页
    private static func placeHotelInvoice(_ bill: BillInfo, loader: SourceLoader, into pages: inout [ComposedPage]) throws {
        let ps = try loader.pages(of: bill)
        if let first = ps.first {
            gridPages([first, first], rows: 2, cols: 1, rotate: false, into: &pages)
        }
        for p in ps.dropFirst() { fullPage(p, into: &pages) }
    }

    /// 滴滴段：行程单 1 张整页、多张 1×2 旋转；发票走发票类分档（带内容框裁切）
    private static func didiSection(
        trips: [BillInfo], invoices: [BillInfo], loader: SourceLoader, into pages: inout [ComposedPage]
    ) throws {
        if trips.count == 1 {
            for p in try loader.pages(of: trips[0]) { fullPage(p, into: &pages) }
        } else if trips.count > 1 {
            try grid(bills: trips, rows: 2, cols: 1, rotate: true, loader: loader, into: &pages)
        }
        try invoiceGrid(bills: invoices, loader: loader, cropToContent: true, into: &pages)
    }

    /// 发票类分档排版（左转 90°）：1 张整页旋转；2 张 1×2 旋转；≥3 张 2×2 旋转
    private static func invoiceGrid(
        bills: [BillInfo], loader: SourceLoader, cropToContent: Bool = false, into pages: inout [ComposedPage]
    ) throws {
        guard !bills.isEmpty else { return }
        if bills.count == 1 {
            for p in try loader.pages(of: bills[0], cropToContent: cropToContent) {
                gridPages([p], rows: 1, cols: 1, rotate: true, into: &pages)
            }
        } else if bills.count == 2 {
            try grid(bills: bills, rows: 2, cols: 1, rotate: true, loader: loader, cropToContent: cropToContent, into: &pages)
        } else {
            try grid(bills: bills, rows: 2, cols: 2, rotate: true, loader: loader, cropToContent: cropToContent, into: &pages)
        }
    }

    // MARK: - 页面构造

    /// 整页放置（内容区 = A4 去边距）
    private static func fullPage(_ page: SourcePage, into pages: inout [ComposedPage]) {
        gridPages([page], rows: 1, cols: 1, rotate: false, into: &pages)
    }

    /// 把若干票据的全部页依次流进 rows×cols 网格
    private static func grid(
        bills: [BillInfo], rows: Int, cols: Int, rotate: Bool,
        loader: SourceLoader, cropToContent: Bool = false, into pages: inout [ComposedPage]
    ) throws {
        var all: [SourcePage] = []
        for b in bills { all.append(contentsOf: try loader.pages(of: b, cropToContent: cropToContent)) }
        gridPages(all, rows: rows, cols: cols, rotate: rotate, into: &pages)
    }

    /// 把页面列表按 rows×cols 分页排入（row 0 在页面顶部）
    private static func gridPages(_ items: [SourcePage], rows: Int, cols: Int, rotate: Bool, into pages: inout [ComposedPage]) {
        guard !items.isEmpty else { return }
        let perPage = rows * cols
        let cellW = (pageW - 2 * margin - CGFloat(cols - 1) * gap) / CGFloat(cols)
        let cellH = (pageH - 2 * margin - CGFloat(rows - 1) * gap) / CGFloat(rows)
        var idx = 0
        while idx < items.count {
            let chunk = Array(items[idx..<min(idx + perPage, items.count)])
            let composed = ComposedPage()
            composed.setBounds(CGRect(x: 0, y: 0, width: pageW, height: pageH), for: .mediaBox)
            for (i, src) in chunk.enumerated() {
                let row = i / cols          // 0 = 顶部行
                let col = i % cols
                let x = margin + CGFloat(col) * (cellW + gap)
                // PDF 坐标原点在左下：顶部行的 y 最大
                let y = pageH - margin - CGFloat(row + 1) * cellH - CGFloat(row) * gap
                composed.placements.append(.init(page: src.page, cell: CGRect(x: x, y: y, width: cellW, height: cellH),
                                                 rotate: rotate, crop: src.crop))
            }
            pages.append(composed)
            idx += perPage
        }
    }
}

// MARK: - 合成页（把源页面按格位矢量绘制进来）

final class ComposedPage: PDFPage {
    struct Placement {
        var page: PDFPage
        var cell: CGRect
        var rotate: Bool
        var crop: CGRect? = nil
    }
    var placements: [Placement] = []

    override func draw(with box: PDFDisplayBox, to context: CGContext) {
        // 白底
        context.saveGState()
        context.setFillColor(NSColor.white.cgColor)
        context.fill(bounds(for: .mediaBox))
        context.restoreGState()

        for placement in placements {
            let src = placement.page
            let media = src.bounds(for: .mediaBox)
            // fit 框：有内容裁切框时按裁切框排版，绘制仍走 mediaBox 全页，
            // 靠源空间裁剪只露出裁切区（不用 cropBox，避免与 draw 的框映射叠加错位）
            let sb = placement.crop ?? media
            guard sb.width > 0, sb.height > 0 else { continue }
            let cell = placement.cell

            context.saveGState()
            context.beginPath()
            context.addRect(cell)
            context.clip()

            if placement.rotate {
                // 左转 90°（逆时针，横向票据转正）：绕格中心旋转，宽高互换后等比 fit
                let s = min(cell.width / sb.height, cell.height / sb.width)
                context.translateBy(x: cell.midX, y: cell.midY)
                context.rotate(by: .pi / 2)
                context.scaleBy(x: s, y: s)
                context.translateBy(x: -sb.midX, y: -sb.midY)
            } else {
                let s = min(cell.width / sb.width, cell.height / sb.height)
                let ox = cell.minX + (cell.width - sb.width * s) / 2
                let oy = cell.minY + (cell.height - sb.height * s) / 2
                context.translateBy(x: ox, y: oy)
                context.scaleBy(x: s, y: s)
                context.translateBy(x: -sb.minX, y: -sb.minY)
            }
            if let crop = placement.crop {
                // 变换后处于源页面空间：把可见区裁到内容框
                context.beginPath()
                context.addRect(crop)
                context.clip()
            }
            src.draw(with: .mediaBox, to: context)
            context.restoreGState()
        }
    }
}

// MARK: - 源文件加载（PDF 逐页 / 图片转页；源文档在合成期间保活）

final class SourceLoader {
    private let originalsDir: URL
    private var keepAlive: [PDFDocument] = []

    init(originalsDir: URL) {
        self.originalsDir = originalsDir
    }

    /// 取一张票据的全部页（多页全纳入）
    /// - Parameter cropToContent: 为每页计算文字内容框（滴滴发票用；取不到时不裁）
    func pages(of bill: BillInfo, cropToContent: Bool = false) throws -> [SourcePage] {
        let url = originalsDir.appendingPathComponent(bill.sourceFile)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PdfComposer.ComposeError.sourceMissing(bill.sourceFile)
        }
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            guard let doc = PDFDocument(url: url) else {
                throw PdfComposer.ComposeError.sourceMissing(bill.sourceFile)
            }
            keepAlive.append(doc)
            var result: [SourcePage] = []
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                result.append(SourcePage(page: page, crop: cropToContent ? Self.contentBounds(of: page) : nil))
            }
            return result
        }
        // 图片：转成一页（PDFPage(image:) 以 72dpi 计点数，fit 逻辑按 bounds 走即可）
        guard let image = NSImage(contentsOf: url), let page = PDFPage(image: image) else {
            throw PdfComposer.ComposeError.sourceMissing(bill.sourceFile)
        }
        return [SourcePage(page: page)]
    }

    /// 页面的文字内容框（全部字符选区的外接矩形，略外扩）；无文字层/异常时返回 nil
    static func contentBounds(of page: PDFPage) -> CGRect? {
        let media = page.bounds(for: .mediaBox)
        guard media.width > 0, media.height > 0 else { return nil }
        guard let text = page.string, !text.isEmpty else { return nil }
        let len = (text as NSString).length
        guard len > 0, let sel = page.selection(for: NSRange(location: 0, length: len)) else { return nil }
        var rect = sel.bounds(for: page)
        guard rect.width > 10, rect.height > 10 else { return nil }
        rect = rect.insetBy(dx: -6, dy: -6).intersection(media)
        let areaRatio = (rect.width * rect.height) / (media.width * media.height)
        // 太小多半是选区异常、几乎整页则没必要裁
        guard areaRatio > 0.08, areaRatio < 0.98 else { return nil }
        return rect
    }
}
