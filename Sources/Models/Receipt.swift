//
//  Receipt.swift
//  报销整理Native
//
//  LLM 识别单张票据后的标准输出结构（对应 core/receipt_schema.py:Receipt）。
//
//  设计原则：
//  1. fields 用 [String: String?] 而不是 [String: Any]，方便 Codable
//  2. 金额统一 String（避免 LLM 输出 553.00 vs 553 的浮点误差；下游需要时再 parseDouble）
//  3. 日期/时间统一字符串（YYYY-MM-DD / HH:mm）
//  4. 错误信息 error != "" 表示识别失败
//

import Foundation

/// 标准 Receipt 数据结构（LLM 输出）
struct Receipt: Codable, Sendable {
    var receiptType: BillType
    var confidence: Double           // 0.0 - 1.0
    var fields: [String: String?]    // 字段值，允许 null
    var rawTextExcerpt: String       // OCR 原文前 500 字
    var recognizedAt: String         // ISO 8601 时间戳
    var sourceFile: String           // 原文件名
    var error: String                // 非空 = 识别失败

    init(
        receiptType: BillType = .other,
        confidence: Double = 0.0,
        fields: [String: String?] = [:],
        rawTextExcerpt: String = "",
        recognizedAt: String = "",
        sourceFile: String = "",
        error: String = ""
    ) {
        self.receiptType = receiptType
        self.confidence = confidence
        self.fields = fields
        self.rawTextExcerpt = rawTextExcerpt
        self.recognizedAt = recognizedAt
        self.sourceFile = sourceFile
        self.error = error
    }

    // CodingKeys: 兼容 Python dataclass 字段名（snake_case）
    enum CodingKeys: String, CodingKey {
        case receiptType = "receipt_type"
        case confidence
        case fields
        case rawTextExcerpt = "raw_text_excerpt"
        case recognizedAt = "recognized_at"
        case sourceFile = "source_file"
        case error
    }

    // 自定义 Decoder：因为 fields 的 value 是 String?，而 JSON 里可能是 null 或缺失；
    // confidence LLM 可能给 0.92 数字也可能给 "0.92" 字符串；fields value 也可能是数字/字符串/布尔。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let typeStr = try c.decode(String.self, forKey: .receiptType)
        self.receiptType = BillType(rawValue: typeStr) ?? .other

        // confidence：优先数字；fallback 字符串解析
        if let d = try? c.decodeIfPresent(Double.self, forKey: .confidence) {
            self.confidence = d
        } else if let s = try? c.decodeIfPresent(String.self, forKey: .confidence), let d = Double(s) {
            self.confidence = d
        } else {
            self.confidence = 0.0
        }

        // fields：先按 [String: Any] 解，再归一化为 String?
        if let rawAny = try? c.decodeIfPresent([String: AnyJSONValue].self, forKey: .fields) {
            self.fields = rawAny.mapValues { $0.toOptionalString }
        } else if let rawStr = try? c.decodeIfPresent([String: String?].self, forKey: .fields) {
            self.fields = rawStr
        } else if let rawStr = try? c.decodeIfPresent([String: String].self, forKey: .fields) {
            self.fields = rawStr.mapValues { $0 as String? }
        } else {
            self.fields = [:]
        }

        self.rawTextExcerpt = try c.decodeIfPresent(String.self, forKey: .rawTextExcerpt) ?? ""
        self.recognizedAt = try c.decodeIfPresent(String.self, forKey: .recognizedAt) ?? ""
        self.sourceFile = try c.decodeIfPresent(String.self, forKey: .sourceFile) ?? ""
        self.error = try c.decodeIfPresent(String.self, forKey: .error) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(receiptType.rawValue, forKey: .receiptType)
        try c.encode(confidence, forKey: .confidence)
        // 过滤掉 nil 让 JSON 干净一点
        let compact = fields.compactMapValues { $0 }
        try c.encode(compact, forKey: .fields)
        try c.encode(rawTextExcerpt, forKey: .rawTextExcerpt)
        try c.encode(recognizedAt, forKey: .recognizedAt)
        try c.encode(sourceFile, forKey: .sourceFile)
        if !error.isEmpty { try c.encode(error, forKey: .error) }
    }

    /// 获取某个字段的字符串值（不存在或为 nil 返回 nil）
    func field(_ key: String) -> String? {
        fields[key] ?? nil
    }

    /// 计算"必填字段覆盖度"（0-1）
    var requiredCoverage: Double {
        let req = BillTypeFields.spec(for: receiptType).required
        guard !req.isEmpty else { return 1.0 }
        let hit = req.filter { fields[$0] != nil }.count
        return Double(hit) / Double(req.count)
    }

    /// 真正"需要人工复核"：error 非空、confidence 太低、或必填字段严重缺失
    var needsReview: Bool {
        !error.isEmpty || confidence < 0.5 || requiredCoverage < 0.5
    }

    // MARK: - 派生：用于行程归类的 key

    /// 用于行程分组的"日期"：优先 departure_date / check_in_date / issue_date
    var tripDate: String? {
        field("departure_date")
            ?? field("check_in_date")
            ?? field("issue_date")
    }

    /// 用于行程分组的"城市"：优先 origin_city / city
    var tripCity: String? {
        field("origin_city") ?? field("city")
    }
}
