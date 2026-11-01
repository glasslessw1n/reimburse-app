//
//  ReceiptTests.swift
//  报销整理Native
//
//  覆盖 Receipt 必填字段覆盖度（null 不应算命中）。
//

import Testing
@testable import 报销整理

struct ReceiptTests {

    @Test func requiredCoverageTreatsNullAsMissing() {
        // dining 必填 amount / issue_date，均显式 null → 覆盖率应为 0
        var r = Receipt(receiptType: .dining)
        r.fields = ["amount": nil, "issue_date": nil]
        #expect(r.requiredCoverage == 0)
    }

    @Test func requiredCoverageFullHit() {
        var r = Receipt(receiptType: .dining)
        r.fields = ["amount": "580", "issue_date": "2026-09-16"]
        #expect(r.requiredCoverage == 1)
    }

    @Test func requiredCoveragePartial() {
        var r = Receipt(receiptType: .dining)
        r.fields = ["amount": "580", "issue_date": nil]
        #expect(r.requiredCoverage == 0.5)
    }

    @Test func requiredCoverageNoRequiredFieldsIsFull() {
        // other 无必填字段 → 覆盖率 1
        let r = Receipt(receiptType: .other)
        #expect(r.requiredCoverage == 1)
    }

    /// 空字符串冒充已填字段不应计覆盖（一期）
    @Test func requiredCoverageEmptyStringNotCovered() {
        var r = Receipt(receiptType: .trainTicket)
        r.fields = ["departure_date": "2026-09-10", "origin_city": "", "destination_city": "厦门", "amount": "553"]
        #expect(r.requiredCoverage == 0.75)
    }

    /// 模型给的越界 confidence（如 92）应钳制到 1（一期）
    @Test func confidenceClampedOnDecode() throws {
        let json = """
        {"receipt_type":"train_ticket","confidence":92,"fields":{},"raw_text_excerpt":"","recognized_at":"","source_file":"a.pdf"}
        """
        let r = try JSONDecoder().decode(Receipt.self, from: Data(json.utf8))
        #expect(r.confidence == 1.0)
    }
}
