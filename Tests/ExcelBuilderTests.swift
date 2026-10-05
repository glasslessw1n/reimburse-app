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
}
