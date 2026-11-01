//
//  ExcelBuilderTests.swift
//  报销整理Native
//
//  覆盖 Excel 明细不丢票据（增值税合并后，行程内的兜底类型必须出现）。
//

import Testing
@testable import 报销整理

struct ExcelBuilderTests {

    @Test func genericTypesNotDroppedInTrip() {
        let bills: [BillInfo] = [
            BillInfo(billType: .trainTicket, amount: 553, sourceFile: "火车票.pdf",
                     fields: ["departure_date": "2026-09-10", "origin_city": "重庆", "destination_city": "厦门"]),
            BillInfo(billType: .taxiTransport, amount: 30, sourceFile: "出租.pdf", fields: ["issue_date": "2026-09-11"]),
            BillInfo(billType: .telecom, amount: 200, sourceFile: "通信.pdf", fields: ["issue_date": "2026-09-11"]),
            BillInfo(billType: .other, amount: 100, sourceFile: "其他.pdf", fields: ["issue_date": "2026-09-11"]),
        ]
        let xml = ExcelBuilder.buildSheet(bills: bills, homeCities: ["重庆"])
        #expect(xml.contains("出租.pdf"), "出租车票不应被漏掉")
        #expect(xml.contains("通信.pdf"), "通信票不应被漏掉")
        #expect(xml.contains("其他.pdf"), "其他票不应被漏掉")
        #expect(xml.contains("报销总计"))
    }

    @Test func localBillsAlsoRendered() {
        // 没有交通票 → 全落到「本地」，本地兜底也要渲染
        let bills: [BillInfo] = [
            BillInfo(billType: .gasInvoice, amount: 300, sourceFile: "加油.pdf", fields: ["issue_date": "2026-09-10"]),
            BillInfo(billType: .tollInvoice, amount: 50, sourceFile: "通行费.pdf", fields: ["issue_date": "2026-09-11"]),
        ]
        let xml = ExcelBuilder.buildSheet(bills: bills, homeCities: ["重庆"])
        #expect(xml.contains("加油.pdf"), "加油票不应被漏掉")
        #expect(xml.contains("通行费.pdf"), "通行费不应被漏掉")
    }

    @Test func hotelFolioAndInvoiceCountedOnce() {
        // 水单+发票同金额 → 同一住宿只计一次，不能重复入表
        let bills: [BillInfo] = [
            BillInfo(billType: .trainTicket, amount: 553, sourceFile: "火车票.pdf",
                     fields: ["departure_date": "2026-09-10", "origin_city": "重庆", "destination_city": "厦门"]),
            BillInfo(billType: .hotelFolio, amount: 1200, sourceFile: "水单.pdf",
                     fields: ["check_in_date": "2026-09-10", "check_out_date": "2026-09-12", "city": "厦门", "hotel_name": "厦门酒店"]),
            BillInfo(billType: .hotelInvoice, amount: 1200, sourceFile: "发票.pdf",
                     fields: ["issue_date": "2026-09-12", "seller_name": "厦门酒店"]),
        ]
        let xml = ExcelBuilder.buildSheet(bills: bills, homeCities: ["重庆"])
        let hotelCount = xml.components(separatedBy: "酒店住宿").count - 1
        #expect(hotelCount == 1, "水单+发票应归并为一行，实际 \(hotelCount) 行")
        #expect(xml.contains("1753.00"), "总计应为 553 + 1200 = 1753")
        #expect(!xml.contains("2953.00"), "不应重复计入酒店金额")
    }

    // MARK: - 滴滴子集和覆盖（一期）

    @Test func didiCoverageSubsetSum() {
        // 一张汇总发票 300 覆盖行程单 100+200（旧实现只认单张相等 → 全额双计）
        let covered = ExcelBuilder.didiCoveredTrips(invoiceAmounts: [300], tripAmounts: [100, 200, 50])
        #expect(covered == [0, 1])
    }

    @Test func didiCoverageNoSubsetNoCover() {
        let covered = ExcelBuilder.didiCoveredTrips(invoiceAmounts: [150], tripAmounts: [100, 200])
        #expect(covered.isEmpty)
    }

    @Test func didiCoverageTwoInvoicesPartition() {
        let covered = ExcelBuilder.didiCoveredTrips(invoiceAmounts: [300, 50], tripAmounts: [100, 200, 50])
        #expect(covered == [0, 1, 2])
    }

    @Test func didiAggregateInvoiceNotDoubleCountedInSheet() {
        let trip = TripGroup(key: "0910-0912", firstMMDD: "0910", lastMMDD: "0912", cities: ["厦门"], bills: [
            BillInfo(billType: .didiTrip, amount: 100, sourceFile: "t1.pdf", fields: ["departure_date": "2026-09-10"]),
            BillInfo(billType: .didiTrip, amount: 200, sourceFile: "t2.pdf", fields: ["departure_date": "2026-09-11"]),
            BillInfo(billType: .didiInvoice, amount: 300, sourceFile: "inv.pdf", fields: ["issue_date": "2026-09-12"]),
        ])
        let xml = ExcelBuilder.buildSheet(trips: [trip], localBills: [])
        #expect(xml.contains("报销总计: ¥300.00"), "汇总发票 300 应只计一次\n\(xml)")
        #expect(!xml.contains("600.00"), "不应把行程单金额再计一遍")
    }

    // MARK: - 酒店一票多住（pairedFolioUID 口径，一期）

    @Test func hotelOneInvoiceTwoFoliosCountedOnce() {
        let folio1 = BillInfo(billType: .hotelFolio, amount: 500, sourceFile: "f1.pdf",
                              fields: ["check_in_date": "2026-09-10", "check_out_date": "2026-09-11", "city": "厦门"])
        let folio2 = BillInfo(billType: .hotelFolio, amount: 500, sourceFile: "f2.pdf",
                              fields: ["check_in_date": "2026-09-11", "check_out_date": "2026-09-12", "city": "厦门"])
        var invoice = BillInfo(billType: .hotelInvoice, amount: 1000, sourceFile: "inv.pdf",
                               fields: ["issue_date": "2026-09-12", "city": "厦门"])
        invoice.pairedFolioUID = folio1.uid
        let trip = TripGroup(key: "0910-0912", firstMMDD: "0910", lastMMDD: "0912", cities: ["厦门"],
                             bills: [folio1, folio2, invoice])
        let xml = ExcelBuilder.buildSheet(trips: [trip], localBills: [])
        #expect(xml.contains("报销总计: ¥1000.00"), "两张水单 500+500，发票只是凭证，不应再计\n\(xml)")
        #expect(!xml.contains("2000.00"), "一票多住不应双计")
    }
}
