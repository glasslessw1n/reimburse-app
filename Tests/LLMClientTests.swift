//
//  LLMClientTests.swift
//  报销整理Native
//
//  覆盖 JSONParser 对 LLM 输出的容错解析。
//

import Foundation
import Testing
@testable import 报销整理

struct LLMClientTests {

    @Test func parsePlainJSON() throws {
        let obj = try JSONParser.extractFirstJSONObject(from: #"{"amount": 580, "receipt_type": "dining"}"#)
        #expect((obj["receipt_type"] as? String) == "dining")
        #expect((obj["amount"] as? NSNumber)?.intValue == 580)
    }

    @Test func parseFencedJSON() throws {
        let text = """
        ```json
        {"receipt_type": "dining"}
        ```
        """
        let obj = try JSONParser.extractFirstJSONObject(from: text)
        #expect((obj["receipt_type"] as? String) == "dining")
    }

    @Test func parseKeepsJsonSubstringInContent() throws {
        // 正文里含 "json" 子串不应被误删（回归：之前用 replacingOccurrences 会删掉）
        let text = """
        ```json
        {"note": "myjsonvalue", "amount": 5}
        ```
        """
        let obj = try JSONParser.extractFirstJSONObject(from: text)
        #expect((obj["note"] as? String) == "myjsonvalue")
    }

    @Test func parseNestedBracesWithSurroundingText() throws {
        let text = "前缀说明 {\"items\": [{\"name\": \"a\"}], \"amount\": 10} 后缀说明"
        let obj = try JSONParser.extractFirstJSONObject(from: text)
        #expect((obj["amount"] as? NSNumber)?.intValue == 10)
    }
}
