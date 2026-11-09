//
//  PackagingTests.swift
//  二期：整合 PDF / 合并 PDF / 提交前检查
//

import Testing
import Foundation
import PDFKit
@testable import 报销整理

struct PackagingTests {

    // MARK: - 工具

    /// 生成指定页数的空白 PDF 数据（200×200 页面）
    private func pdfData(pages: Int) -> Data {
        let doc = PDFDocument()
        for i in 0..<pages {
            let page = PDFPage()
            page.setBounds(CGRect(x: 0, y: 0, width: 200, height: 200), for: .mediaBox)
            doc.insert(page, at: i)
        }
        return doc.dataRepresentation()!
    }

    /// 把 bills 的 sourceFile 逐一写成临时 PDF，返回 originals 目录
    private func makeOriginals(_ bills: [BillInfo], pagesPerFile: Int = 1) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pkg-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for bill in bills where bill.sourceFile.hasSuffix(".pdf") {
            try pdfData(pages: pagesPerFile).write(to: dir.appendingPathComponent(bill.sourceFile))
        }
        return dir
    }

    private func pageCount(of data: Data) -> Int {
        PDFDocument(data: data)?.pageCount ?? -1
    }

    // MARK: - 整合 PDF 页数

    @Test func composerTransportProofAndGrid() throws {
        // 交通 3 张：证明页 P1（首+尾）1 页 + 3×2 网格 1 页 = 2 页
        let bills = [
            BillInfo(billType: .trainTicket, amount: 100, sourceFile: "t1.pdf", fields: ["departure_date": "2026-09-10"]),
            BillInfo(billType: .flightItinerary, amount: 200, sourceFile: "t2.pdf", fields: ["issue_date": "2026-09-11"]),
            BillInfo(billType: .boardingPass, amount: 0, sourceFile: "t3.pdf", fields: ["departure_date": "2026-09-12"]),
        ]
        let dir = try makeOriginals(bills)
        defer { try? FileManager.default.removeItem(at: dir) }
        let trip = TripGroup(key: "0910-0912", firstMMDD: "0910", lastMMDD: "0912", cities: ["厦门"], bills: bills)
        let data = try PdfComposer.compose(trips: [trip], local: [], originalsDir: dir)
        #expect(pageCount(of: data) == 2)
    }

    @Test func composerLoneBoardingPassOnlyOnProofPage() throws {
        // 孤张登机牌：只在证明页出现一次，不再进交通票网格重复排
        let bills = [
            BillInfo(billType: .boardingPass, amount: 0, sourceFile: "bp.pdf", fields: ["departure_date": "2026-09-10"]),
        ]
        let dir = try makeOriginals(bills)
        defer { try? FileManager.default.removeItem(at: dir) }
        let trip = TripGroup(key: "0910-0910", firstMMDD: "0910", lastMMDD: "0910", cities: ["厦门"], bills: bills)
        let data = try PdfComposer.compose(trips: [trip], local: [], originalsDir: dir)
        #expect(pageCount(of: data) == 1)
    }

    @Test func composerHotelFolioFullInvoiceDoubled() throws {
        // 水单整页 1 + 发票同页两份 1 = 2 页
        let bills = [
            BillInfo(billType: .hotelFolio, amount: 500, sourceFile: "f.pdf", fields: ["check_in_date": "2026-09-10"]),
            BillInfo(billType: .hotelInvoice, amount: 500, sourceFile: "i.pdf", fields: ["issue_date": "2026-09-12"]),
        ]
        let dir = try makeOriginals(bills)
        defer { try? FileManager.default.removeItem(at: dir) }
        let trip = TripGroup(key: "0910-0912", firstMMDD: "0910", lastMMDD: "0912", cities: ["厦门"], bills: bills)
        let data = try PdfComposer.compose(trips: [trip], local: [], originalsDir: dir)
        #expect(pageCount(of: data) == 2)
    }

    @Test func composerMultiPageDocumentFullyIncluded() throws {
        // 多页文档（2 页餐饮小票扫描件）：单张发票走整页旋转档，两页各占一整页，全纳入
        let bills = [
            BillInfo(billType: .dining, amount: 88, sourceFile: "d.pdf", fields: ["issue_date": "2026-09-10"]),
        ]
        let dir = try makeOriginals(bills, pagesPerFile: 2)
        defer { try? FileManager.default.removeItem(at: dir) }
        let trip = TripGroup(key: "0910-0910", firstMMDD: "0910", lastMMDD: "0910", cities: ["厦门"], bills: bills)
        let data = try PdfComposer.compose(trips: [trip], local: [], originalsDir: dir)
        #expect(pageCount(of: data) == 2)
    }

    @Test func composerBoardingPassesOnlyOnProofPage() throws {
        // 登机牌 3 张 + 行程单 1 张：证明页用起止两张登机牌（1 页），中间一张弃用；
        // 交通票网格只有行程单（1 页）→ 共 2 页
        let bills = [
            BillInfo(billType: .boardingPass, amount: 0, sourceFile: "bp1.pdf", fields: ["departure_date": "2026-09-10"]),
            BillInfo(billType: .boardingPass, amount: 0, sourceFile: "bp2.pdf", fields: ["departure_date": "2026-09-12"]),
            BillInfo(billType: .boardingPass, amount: 0, sourceFile: "bp3.pdf", fields: ["departure_date": "2026-09-14"]),
            BillInfo(billType: .flightItinerary, amount: 900, sourceFile: "fi.pdf", fields: ["issue_date": "2026-09-10"]),
        ]
        let dir = try makeOriginals(bills)
        defer { try? FileManager.default.removeItem(at: dir) }
        let trip = TripGroup(key: "0910-0914", firstMMDD: "0910", lastMMDD: "0914", cities: ["厦门"], bills: bills)
        let data = try PdfComposer.compose(trips: [trip], local: [], originalsDir: dir)
        #expect(pageCount(of: data) == 2)
    }

    @Test func composerHotelPairsStayAdjacent() throws {
        // 两组水单+发票：每组 水单整页 + 发票两份页 = 2 页，两组共 4 页
        let folio1 = BillInfo(billType: .hotelFolio, amount: 500, sourceFile: "f1.pdf",
                              fields: ["check_in_date": "2026-09-10", "check_out_date": "2026-09-11"])
        var inv1 = BillInfo(billType: .hotelInvoice, amount: 500, sourceFile: "i1.pdf", fields: ["issue_date": "2026-09-11"])
        inv1.pairedFolioUID = folio1.uid
        let folio2 = BillInfo(billType: .hotelFolio, amount: 600, sourceFile: "f2.pdf",
                              fields: ["check_in_date": "2026-09-11", "check_out_date": "2026-09-12"])
        var inv2 = BillInfo(billType: .hotelInvoice, amount: 600, sourceFile: "i2.pdf", fields: ["issue_date": "2026-09-12"])
        inv2.pairedFolioUID = folio2.uid
        let bills = [folio1, inv1, folio2, inv2]
        let dir = try makeOriginals(bills)
        defer { try? FileManager.default.removeItem(at: dir) }
        let trip = TripGroup(key: "0910-0912", firstMMDD: "0910", lastMMDD: "0912", cities: ["厦门"], bills: bills)
        let data = try PdfComposer.compose(trips: [trip], local: [], originalsDir: dir)
        #expect(pageCount(of: data) == 4)
    }

    @Test func composerDidiTwoInvoicesOneByTwo() throws {
        // 滴滴发票 2 张 → 1×2 不旋转一页（2026-11-09 分档修订：2 张不旋转）
        var i1 = BillInfo(billType: .didiInvoice, amount: 100, sourceFile: "di1.pdf", fields: ["issue_date": "2026-09-12"])
        i1.didiLetter = "A"
        var i2 = BillInfo(billType: .didiInvoice, amount: 120, sourceFile: "di2.pdf", fields: ["issue_date": "2026-09-12"])
        i2.didiLetter = "B"
        let bills = [i1, i2]
        let dir = try makeOriginals(bills)
        defer { try? FileManager.default.removeItem(at: dir) }
        let trip = TripGroup(key: "0910-0912", firstMMDD: "0910", lastMMDD: "0912", cities: ["厦门"], bills: bills)
        let data = try PdfComposer.compose(trips: [trip], local: [], originalsDir: dir)
        #expect(pageCount(of: data) == 1)
    }

    @Test func composerDidiTwoTripsOneInvoice() throws {
        // 行程单 2 张 → 1×2 旋转 1 页；发票 1 张 → 旋转整页 1 页 = 2 页
        var t1 = BillInfo(billType: .didiTrip, amount: 100, sourceFile: "dt1.pdf", fields: ["departure_date": "2026-09-10"])
        t1.didiLetter = "A"
        var t2 = BillInfo(billType: .didiTrip, amount: 120, sourceFile: "dt2.pdf", fields: ["departure_date": "2026-09-11"])
        t2.didiLetter = "B"
        var inv = BillInfo(billType: .didiInvoice, amount: 220, sourceFile: "di.pdf", fields: ["issue_date": "2026-09-12"])
        inv.didiLetter = "A"
        let bills = [t1, t2, inv]
        let dir = try makeOriginals(bills)
        defer { try? FileManager.default.removeItem(at: dir) }
        let trip = TripGroup(key: "0910-0912", firstMMDD: "0910", lastMMDD: "0912", cities: ["厦门"], bills: bills)
        let data = try PdfComposer.compose(trips: [trip], local: [], originalsDir: dir)
        #expect(pageCount(of: data) == 2)
    }

    // MARK: - 合并 PDF

    @Test func mergerConcatenatesAllPagesInCategoryOrder() throws {
        // 火车票 2 页 + 餐饮 1 页 = 3 页；顺序上交通类在餐饮前
        let bills = [
            BillInfo(billType: .dining, amount: 50, sourceFile: "d.pdf", fields: ["issue_date": "2026-09-10"]),
            BillInfo(billType: .trainTicket, amount: 100, sourceFile: "t.pdf", fields: ["departure_date": "2026-09-10"]),
        ]
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pkg-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try pdfData(pages: 1).write(to: dir.appendingPathComponent("d.pdf"))
        try pdfData(pages: 2).write(to: dir.appendingPathComponent("t.pdf"))

        let ordered = PdfMerger.orderedBills(bills, isLocal: false)
        #expect(ordered.map { $0.billType } == [.trainTicket, .dining])

        let trip = TripGroup(key: "0910-0910", firstMMDD: "0910", lastMMDD: "0910", cities: ["厦门"], bills: bills)
        let data = try PdfMerger.merge(trips: [trip], local: [], originalsDir: dir)
        #expect(pageCount(of: data) == 3)
    }

    // MARK: - 提交前检查

    @Test func preflightTotalsUseExcelRules() {
        // 滴滴汇总发票 300 覆盖行程单 100+200 → 滴滴合计 300（不双计）
        // 酒店发票与水单已配对 → 酒店合计只计水单 500
        let folio = BillInfo(billType: .hotelFolio, amount: 500, sourceFile: "f.pdf",
                             fields: ["check_in_date": "2026-09-10", "check_out_date": "2026-09-12"])
        var invoice = BillInfo(billType: .hotelInvoice, amount: 500, sourceFile: "i.pdf",
                               fields: ["issue_date": "2026-09-12"])
        invoice.pairedFolioUID = folio.uid
        let trip = TripGroup(key: "0910-0912", firstMMDD: "0910", lastMMDD: "0912", cities: ["厦门"], bills: [
            folio, invoice,
            BillInfo(billType: .didiTrip, amount: 100, sourceFile: "dt1.pdf", fields: ["departure_date": "2026-09-10"]),
            BillInfo(billType: .didiTrip, amount: 200, sourceFile: "dt2.pdf", fields: ["departure_date": "2026-09-11"]),
            BillInfo(billType: .didiInvoice, amount: 300, sourceFile: "di.pdf", fields: ["issue_date": "2026-09-12"]),
        ])
        let totals = Dictionary(uniqueKeysWithValues: Preflight.categoryTotals(trips: [trip], local: []).map { ($0.name, $0.amount) })
        #expect(totals["滴滴"] == 300)
        #expect(totals["酒店"] == 500)
    }

    @MainActor
    @Test func preflightFlagsHotelFolioWithoutInvoice() throws {
        let sid = UUID().uuidString.lowercased()
        let session = SessionManager(sid: sid)
        defer { try? FileManager.default.removeItem(at: session.rootDir) }
        // 写入一张水单原文件并 ingest（未整理也可查：会走现场分组兜底）
        let pdfURL = session.rootDir.appendingPathComponent("originals/folio.pdf")
        try pdfData(pages: 1).write(to: pdfURL)
        let folio = BillInfo(billType: .hotelFolio, amount: 500, sourceFile: "folio.pdf",
                             fields: ["check_in_date": "2026-09-10", "check_out_date": "2026-09-12", "city": "厦门"])
        session.ingest(folio)
        let report = Preflight.check(session: session)
        #expect(report.items.contains { $0.title.contains("住宿缺发票") },
                "应提示水单缺发票，实际：\(report.items.map { $0.title })")
    }
}
