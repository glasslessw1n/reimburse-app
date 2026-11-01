//
//  PdfMerger.swift
//  报销整理Native
//
//  简单合并 PDF：按整理顺序（与整合 PDF 相同的类别顺序）把全部票据原样矢量拼接，
//  不排版、不缩放。对应 reimburse-toolkit 的 merge.py（并补上它遗漏的自驾组）。
//

import Foundation
import PDFKit

enum PdfMerger {

    /// 按顺序合并并返回 PDF 数据
    static func merge(trips: [TripGroup], local: [BillInfo], originalsDir: URL) throws -> Data {
        var ordered: [BillInfo] = []
        for trip in trips { ordered.append(contentsOf: orderedBills(trip.bills, isLocal: false)) }
        if !local.isEmpty { ordered.append(contentsOf: orderedBills(local, isLocal: true)) }
        guard !ordered.isEmpty else { throw PdfComposer.ComposeError.noBills }

        let loader = SourceLoader(originalsDir: originalsDir)
        let doc = PDFDocument()
        var idx = 0
        for bill in ordered {
            for page in try loader.pages(of: bill) {
                // 从源文档取出的页插入新文档时需要复制，避免跨文档引用失效
                guard let copy = page.copy() as? PDFPage else { continue }
                doc.insert(copy, at: idx)
                idx += 1
            }
        }
        guard idx > 0, let data = doc.dataRepresentation() else {
            throw PdfComposer.ComposeError.noBills
        }
        return data
    }

    /// 类别顺序：自驾行程单 → 加油/通行费 → 交通 → 酒店对（水单→发票）→ 滴滴行程单 → 滴滴发票 → 餐饮 → 其他
    /// 本地段：通信 → 滴滴 → 餐饮 → 其他（酒店发票归其他）
    static func orderedBills(_ bills: [BillInfo], isLocal: Bool) -> [BillInfo] {
        let byDate: (BillInfo, BillInfo) -> Bool = { ($0.dateRange.start, $0.sourceFile) < ($1.dateRange.start, $1.sourceFile) }
        func of(_ types: BillType...) -> [BillInfo] {
            bills.filter { types.contains($0.billType) }.sorted(by: byDate)
        }
        if isLocal {
            let handled: Set<BillType> = [.telecom, .didiTrip, .didiInvoice, .dining]
            return of(.telecom)
                + bills.filter { $0.billType == .didiTrip }.sorted { $0.didiLetter < $1.didiLetter }
                + bills.filter { $0.billType == .didiInvoice }.sorted { $0.didiLetter < $1.didiLetter }
                + of(.dining)
                + bills.filter { !handled.contains($0.billType) }.sorted(by: byDate)
        }
        let handled: Set<BillType> = [.selfDriveSheet, .gasInvoice, .tollInvoice, .trainTicket,
                                      .flightItinerary, .boardingPass, .hotelFolio, .hotelInvoice,
                                      .didiTrip, .didiInvoice, .dining]
        var result: [BillInfo] = []
        result += of(.selfDriveSheet)
        result += of(.gasInvoice, .tollInvoice)
        result += of(.trainTicket, .flightItinerary, .boardingPass)
        // 酒店对：按水单顺序，水单后紧跟其配对发票；未配对发票排在本组末尾
        let folios = of(.hotelFolio)
        let invoices = of(.hotelInvoice)
        var usedInvoices = Set<String>()
        for folio in folios {
            result.append(folio)
            if let inv = invoices.first(where: { $0.pairedFolioUID == folio.uid }) {
                result.append(inv)
                usedInvoices.insert(inv.uid)
            }
        }
        result += invoices.filter { !usedInvoices.contains($0.uid) }
        result += bills.filter { $0.billType == .didiTrip }.sorted { $0.didiLetter < $1.didiLetter }
        result += bills.filter { $0.billType == .didiInvoice }.sorted { $0.didiLetter < $1.didiLetter }
        result += of(.dining)
        result += bills.filter { !handled.contains($0.billType) }.sorted(by: byDate)
        return result
    }
}
