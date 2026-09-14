//
//  SessionManifest.swift
//  报销整理Native
//
//  一个 session 的清单（识别后的所有票据 + 行程归类）。
//  对应 core/collector.py:SessionManifest + BillInfo。
//
//  BillInfo 是 Receipt 的扁平版（去掉 Receipt 自有的 LLM 字段，加 amount/date_range/cities），
//  供 collector/packager/filler 共用。
//

import Foundation

/// 单张票据的扁平信息（识别后供前端/打包/填报用）
struct BillInfo: Codable, Identifiable, Sendable {
    var id: String { sourceFile + "_" + String(amount) }

    var billType: BillType
    var dateMMDDs: [String] = []            // 涉及的全部 MMDD（如 ["0303", "0304"]）
    var dateRange: (start: String, end: String) = ("", "")  // 入住-离店 / 行程起止
    var cities: [String] = []
    var fromCity: String = ""
    var toCity: String = ""
    var amount: Double = 0
    var sourceFile: String = ""            // 原文件名
    var targetFilename: String = ""        // 整理后的新文件名
    var targetSubdir: String = ""          // 行程子目录名
    var needsReview: Bool = false
    var reviewReason: String = ""
    var confidence: Double = 1.0
    var fields: [String: String?] = [:]    // 透传 LLM 字段
    var rawTextSnippet: String = ""        // OCR 原文前 N 字
    var error: String = ""
    /// 滴滴行程/发票配对字母（A/B/C...）；通行费序号也借用这个字段
    var didiLetter: String = ""
    /// match 后的最终目标文件名（hotel invoice 关联 folio 后可能改名）
    var finalTargetName: String = ""

    enum CodingKeys: String, CodingKey {
        case billType = "bill_type"
        case dateMMDDs = "date_mmdds"
        case dateRange = "date_range"
        case cities, fromCity = "from_city", toCity = "to_city"
        case amount
        case sourceFile = "source_file"
        case targetFilename = "target_filename"
        case targetSubdir = "target_subdir"
        case needsReview = "needs_review"
        case reviewReason = "review_reason"
        case confidence, fields
        case rawTextSnippet = "raw_text_snippet"
        case error
        case didiLetter = "didi_letter"
        case finalTargetName = "_final_target_name"
    }

    init(
        billType: BillType,
        amount: Double = 0,
        sourceFile: String = "",
        fields: [String: String?] = [:],
        needsReview: Bool = false,
        reviewReason: String = "",
        confidence: Double = 1.0,
        rawTextSnippet: String = "",
        error: String = ""
    ) {
        self.billType = billType
        self.amount = amount
        self.sourceFile = sourceFile
        self.fields = fields
        self.needsReview = needsReview
        self.reviewReason = reviewReason
        self.confidence = confidence
        self.rawTextSnippet = rawTextSnippet
        self.error = error

        // 从 fields 派生 dateMMDDs / dateRange / cities
        var mmdds: [String] = []
        let dateKeys = ["departure_date", "check_in_date", "issue_date"]
        for k in dateKeys {
            if let d = fields[k] ?? nil, d.count >= 10 {
                let mmdd = String(d.suffix(5).prefix(5)).replacingOccurrences(of: "-", with: "")
                mmdds.append(mmdd)
            }
        }
        // check_out_date 单独
        if let co = fields["check_out_date"] ?? nil, co.count >= 10 {
            let mmdd = String(co.suffix(5).prefix(5)).replacingOccurrences(of: "-", with: "")
            mmdds.append(mmdd)
        }
        self.dateMMDDs = Array(Set(mmdds)).sorted()

        // dateRange：优先 check_in/check_out → 退化到 departure_date
        let ci = fields["check_in_date"] ?? nil
        let co = fields["check_out_date"] ?? nil
        if let ci = ci {
            self.dateRange = (String(ci.prefix(10)), String((co ?? ci).prefix(10)))
        } else if let dep = fields["departure_date"] ?? nil {
            self.dateRange = (String(dep.prefix(10)), String(dep.prefix(10)))
        } else if let iss = fields["issue_date"] ?? nil {
            self.dateRange = (String(iss.prefix(10)), String(iss.prefix(10)))
        }

        // cities
        var cs: [String] = []
        for k in ["origin_city", "destination_city", "city"] {
            if let c = fields[k] ?? nil, !c.isEmpty {
                cs.append(c)
            }
        }
        self.cities = cs
        self.fromCity = fields["origin_city"].flatMap { $0 } ?? ""
        self.toCity = fields["destination_city"].flatMap { $0 } ?? ""
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let typeStr = try c.decode(String.self, forKey: .billType)
        self.billType = BillType(rawValue: typeStr) ?? .other
        self.dateMMDDs = try c.decodeIfPresent([String].self, forKey: .dateMMDDs) ?? []
        if let range = try c.decodeIfPresent([String].self, forKey: .dateRange), range.count >= 2 {
            self.dateRange = (range[0], range[1])
        }
        self.cities = try c.decodeIfPresent([String].self, forKey: .cities) ?? []
        self.fromCity = try c.decodeIfPresent(String.self, forKey: .fromCity) ?? ""
        self.toCity = try c.decodeIfPresent(String.self, forKey: .toCity) ?? ""
        self.amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 0
        self.sourceFile = try c.decodeIfPresent(String.self, forKey: .sourceFile) ?? ""
        self.targetFilename = try c.decodeIfPresent(String.self, forKey: .targetFilename) ?? ""
        self.targetSubdir = try c.decodeIfPresent(String.self, forKey: .targetSubdir) ?? ""
        self.needsReview = try c.decodeIfPresent(Bool.self, forKey: .needsReview) ?? false
        self.reviewReason = try c.decodeIfPresent(String.self, forKey: .reviewReason) ?? ""
        self.confidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 1.0
        self.fields = try c.decodeIfPresent([String: String?].self, forKey: .fields) ?? [:]
        self.rawTextSnippet = try c.decodeIfPresent(String.self, forKey: .rawTextSnippet) ?? ""
        self.error = try c.decodeIfPresent(String.self, forKey: .error) ?? ""
        self.didiLetter = try c.decodeIfPresent(String.self, forKey: .didiLetter) ?? ""
        self.finalTargetName = try c.decodeIfPresent(String.self, forKey: .finalTargetName) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(billType.rawValue, forKey: .billType)
        try c.encode(dateMMDDs, forKey: .dateMMDDs)
        try c.encode([dateRange.start, dateRange.end], forKey: .dateRange)
        try c.encode(cities, forKey: .cities)
        if !fromCity.isEmpty { try c.encode(fromCity, forKey: .fromCity) }
        if !toCity.isEmpty { try c.encode(toCity, forKey: .toCity) }
        try c.encode(amount, forKey: .amount)
        try c.encode(sourceFile, forKey: .sourceFile)
        if !targetFilename.isEmpty { try c.encode(targetFilename, forKey: .targetFilename) }
        if !targetSubdir.isEmpty { try c.encode(targetSubdir, forKey: .targetSubdir) }
        if needsReview { try c.encode(true, forKey: .needsReview) }
        if !reviewReason.isEmpty { try c.encode(reviewReason, forKey: .reviewReason) }
        try c.encode(confidence, forKey: .confidence)
        let compact = fields.compactMapValues { $0 }
        if !compact.isEmpty { try c.encode(compact, forKey: .fields) }
        if !rawTextSnippet.isEmpty { try c.encode(rawTextSnippet, forKey: .rawTextSnippet) }
        if !error.isEmpty { try c.encode(error, forKey: .error) }
        if !didiLetter.isEmpty { try c.encode(didiLetter, forKey: .didiLetter) }
        if !finalTargetName.isEmpty { try c.encode(finalTargetName, forKey: .finalTargetName) }
    }
}

/// 行程分组
struct TripGroup: Codable, Identifiable, Sendable {
    var id: String { key }
    var key: String
    var firstMMDD: String
    var lastMMDD: String
    var cities: [String]
    var bills: [BillInfo]

    enum CodingKeys: String, CodingKey {
        case key
        case firstMMDD = "first_mmdd"
        case lastMMDD = "last_mmdd"
        case cities, bills
    }

    /// 生成目录名：`0827-0904 北京 上海`
    var dirname: String {
        let head = (firstMMDD == lastMMDD) ? firstMMDD : "\(firstMMDD)-\(lastMMDD)"
        let deduped = cities.reduce(into: [String]()) { acc, c in
            if isRealCity(c) && (acc.last != c) { acc.append(c) }
        }
        let cityStr = deduped.joined(separator: " ")
        return cityStr.isEmpty ? head : "\(head) \(cityStr)"
    }

    func isRealCity(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        if name.contains(" ") { return false }
        // 含拉丁字符直接 false
        if name.contains(where: { ($0 >= "a" && $0 <= "z") || ($0 >= "A" && $0 <= "Z") }) {
            return false
        }
        if name.count > 6 { return false }
        return true
    }

    init(key: String, firstMMDD: String, lastMMDD: String, cities: [String] = [], bills: [BillInfo] = []) {
        self.key = key
        self.firstMMDD = firstMMDD
        self.lastMMDD = lastMMDD
        self.cities = cities
        self.bills = bills
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.key = try c.decode(String.self, forKey: .key)
        self.firstMMDD = try c.decode(String.self, forKey: .firstMMDD)
        self.lastMMDD = try c.decode(String.self, forKey: .lastMMDD)
        self.cities = try c.decodeIfPresent([String].self, forKey: .cities) ?? []
        self.bills = try c.decodeIfPresent([BillInfo].self, forKey: .bills) ?? []
    }
}

/// Session 全量清单
struct SessionManifest: Codable, Sendable {
    var sid: String
    var createdAt: String
    var ocrAvailable: Bool
    var llmAvailable: Bool
    var bills: [BillInfo]
    var trips: [TripGroup]
    var local: [BillInfo]
    var needsReviewCount: Int

    enum CodingKeys: String, CodingKey {
        case sid
        case createdAt = "created_at"
        case ocrAvailable = "ocr_available"
        case llmAvailable = "llm_available"
        case bills, trips, local
        case needsReviewCount = "needs_review_count"
    }

    init(sid: String, createdAt: String, ocrAvailable: Bool, llmAvailable: Bool) {
        self.sid = sid
        self.createdAt = createdAt
        self.ocrAvailable = ocrAvailable
        self.llmAvailable = llmAvailable
        self.bills = []
        self.trips = []
        self.local = []
        self.needsReviewCount = 0
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.sid = try c.decode(String.self, forKey: .sid)
        self.createdAt = try c.decode(String.self, forKey: .createdAt)
        self.ocrAvailable = try c.decodeIfPresent(Bool.self, forKey: .ocrAvailable) ?? false
        self.llmAvailable = try c.decodeIfPresent(Bool.self, forKey: .llmAvailable) ?? false
        self.bills = try c.decodeIfPresent([BillInfo].self, forKey: .bills) ?? []
        self.trips = try c.decodeIfPresent([TripGroup].self, forKey: .trips) ?? []
        self.local = try c.decodeIfPresent([BillInfo].self, forKey: .local) ?? []
        self.needsReviewCount = try c.decodeIfPresent(Int.self, forKey: .needsReviewCount) ?? 0
    }
}
