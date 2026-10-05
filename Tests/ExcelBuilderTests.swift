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
}
