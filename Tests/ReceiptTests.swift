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
}
