//
//  SessionManagerTests.swift
//  报销整理Native
//
//  覆盖文件名生成、滴滴发票↔行程单配对、滴滴字母编号。
//

import Testing
@testable import 报销整理

@MainActor
struct SessionManagerTests {

    // MARK: - buildFilename

    @Test func buildFilenameHotelFolio() {
        let bill = BillInfo(
            billType: .hotelFolio,
            amount: 1200,
            sourceFile: "水单.pdf",
            fields: [
                "hotel_name": "厦门某酒店",
                "check_in_date": "2026-09-10",
                "check_out_date": "2026-09-12",
                "city": "厦门"
            ]
        )
        #expect(SessionManager.buildFilename(for: bill) == "0910-0912 厦门住宿水单.pdf")
    }

    @Test func buildFilenameDidiTripWithLetter() {
        var bill = BillInfo(billType: .didiTrip, amount: 64, sourceFile: "a.pdf", fields: ["departure_date": "2026-09-15"])
        bill.didiLetter = "A"
        #expect(SessionManager.buildFilename(for: bill) == "滴滴出行行程报销单A.pdf")
    }

    @Test func buildFilenameOtherFallsBackToSourceName() {
        let bill = BillInfo(billType: .other, sourceFile: "报销单据.pdf")
        #expect(SessionManager.buildFilename(for: bill) == "报销单据.pdf")
    }

    @Test func buildFilenameDining() {
        let bill = BillInfo(billType: .dining, amount: 580, sourceFile: "餐饮.pdf", fields: ["issue_date": "2026-09-16"])
        #expect(SessionManager.buildFilename(for: bill) == "0916 餐饮发票 580.pdf")
    }

    // MARK: - 滴滴配对

    /// 滴滴发票按金额配对到行程单后，应继承行程单日期（用于归到同一行程）
    @Test func linkDidiInvoicesCopiesTripDateToInvoice() {
        let trip = BillInfo(billType: .didiTrip, amount: 172.9, sourceFile: "trip.pdf", fields: ["departure_date": "2026-09-22"])
        let invoice = BillInfo(billType: .didiInvoice, amount: 172.9, sourceFile: "inv.pdf", fields: ["issue_date": "2026-09-26"])
        var bills = [trip, invoice]
        SessionManager.linkDidiInvoices(bills: &bills)
        #expect(bills[1].dateMMDDs == ["0922"])
        #expect(bills[1].dateRange.start == "2026-09-22")
    }

    /// 金额不匹配的发票不应被改动
    @Test func linkDidiInvoicesLeavesUnmatchedInvoice() {
        let trip = BillInfo(billType: .didiTrip, amount: 100, sourceFile: "trip.pdf", fields: ["departure_date": "2026-09-22"])
        let invoice = BillInfo(billType: .didiInvoice, amount: 999, sourceFile: "inv.pdf", fields: ["issue_date": "2026-09-26"])
        var bills = [trip, invoice]
        SessionManager.linkDidiInvoices(bills: &bills)
        #expect(bills[1].dateMMDDs == ["0926"])
    }

    // MARK: - 酒店水单↔发票匹配

    /// 金额相同的两家酒店，发票应按「酒店名相似度」匹配到正确那家（而非只看金额）
    @Test func hotelMatchDisambiguatesSameAmountByName() {
        var bills: [BillInfo] = [
            BillInfo(billType: .hotelFolio, amount: 800, sourceFile: "folio_sh.pdf",
                     fields: ["hotel_name": "上海外滩茂悦大酒店", "city": "上海",
                              "check_in_date": "2026-09-10", "check_out_date": "2026-09-12"]),
            BillInfo(billType: .hotelFolio, amount: 800, sourceFile: "folio_gz.pdf",
                     fields: ["hotel_name": "广州珠江大酒店", "city": "广州",
                              "check_in_date": "2026-09-10", "check_out_date": "2026-09-12"]),
            BillInfo(billType: .hotelInvoice, amount: 800, sourceFile: "inv.pdf",
                     fields: ["seller_name": "上海外滩茂悦大酒店", "issue_date": "2026-09-12"]),
        ]
        SessionManager.matchAndEnrichHotel(bills: &bills)
        let invoice = bills[2]
        // 应借用「上海外滩茂悦」水单的酒店名与城市，而非金额相同的广州那家
        #expect(invoice.fields["hotel_name"] ?? nil == "上海外滩茂悦大酒店")
        #expect(invoice.cities == ["上海"])
    }

    // MARK: - 滴滴字母按时间先后编号

    @Test func assignSequencesChronologicalLetters() {
        var container: [BillInfo] = [
            BillInfo(billType: .didiTrip, amount: 202.7, sourceFile: "b.pdf",
                     fields: ["departure_date": "2026-09-10", "trip_period": "2026-09-10 17:13 至 2026-09-12 09:52"]),
            BillInfo(billType: .didiTrip, amount: 171.6, sourceFile: "a.pdf",
                     fields: ["departure_date": "2026-09-10", "trip_period": "2026-09-10 11:24 至 2026-09-12 14:04"]),
        ]
        SessionManager.assignSequences(in: &container)
        // 11:24 的 171.6 → A；17:13 的 202.7 → B（按时间先后，而非上传顺序）
        #expect(container[0].didiLetter == "B")
        #expect(container[1].didiLetter == "A")
    }

    @Test func assignSequencesInvoiceMatchesTripLetter() {
        var container: [BillInfo] = [
            BillInfo(billType: .didiTrip, amount: 171.6, sourceFile: "t1.pdf", fields: ["departure_date": "2026-09-10"]),
            BillInfo(billType: .didiInvoice, amount: 171.6, sourceFile: "i1.pdf", fields: ["issue_date": "2026-09-26"]),
        ]
        SessionManager.assignSequences(in: &container)
        #expect(container[0].didiLetter == "A")
        #expect(container[1].didiLetter == "A")  // 发票按金额匹配行程单的字母
    }

    // MARK: - 一期：配对门槛 / 未配对显形 / 损坏恢复

    /// 同额但名称、城市都对不上的酒店发票不应被自动配对，且要标记待复核
    @Test func hotelMatchRejectsDifferentHotelSameAmount() {
        var bills: [BillInfo] = [
            BillInfo(billType: .hotelFolio, amount: 800, sourceFile: "folio.pdf",
                     fields: ["hotel_name": "厦门海悦山庄酒店", "city": "厦门",
                              "check_in_date": "2026-09-10", "check_out_date": "2026-09-12"]),
            BillInfo(billType: .hotelInvoice, amount: 800, sourceFile: "inv.pdf",
                     fields: ["seller_name": "北京饭店", "city": "北京", "issue_date": "2026-09-12"]),
        ]
        SessionManager.matchAndEnrichHotel(bills: &bills)
        #expect(bills[1].pairedFolioUID == nil, "名称城市都对不上不应配对")
        #expect(bills[1].needsReview, "未配对应标记待复核")
    }

    /// 滴滴发票未匹配到行程单时保留自身日期并标记待复核
    @Test func linkDidiInvoicesFlagsUnmatched() {
        let trip = BillInfo(billType: .didiTrip, amount: 100, sourceFile: "trip.pdf", fields: ["departure_date": "2026-09-22"])
        let invoice = BillInfo(billType: .didiInvoice, amount: 999, sourceFile: "inv.pdf", fields: ["issue_date": "2026-09-26"])
        var bills = [trip, invoice]
        SessionManager.linkDidiInvoices(bills: &bills)
        #expect(bills[1].dateMMDDs == ["0926"])
        #expect(bills[1].needsReview)
    }

    /// manifest 损坏时应备份原文件并重建，而不是静默覆盖
    @Test func corruptedManifestIsBackedUpNotSilentlyWiped() throws {
        let sid = UUID().uuidString.lowercased()
        let first = SessionManager(sid: sid)
        let manifestURL = first.rootDir.appendingPathComponent("manifest.json")
        try Data("{\"broken\": ".utf8).write(to: manifestURL)

        let second = SessionManager(sid: sid)
        #expect(second.recoveredFromCorruption)
        #expect(second.manifest.bills.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: second.rootDir.path)
        #expect(files.contains { $0.hasPrefix("manifest.corrupt-") }, "应留下损坏备份，实际：\(files)")
        try? FileManager.default.removeItem(at: second.rootDir)
    }
}
