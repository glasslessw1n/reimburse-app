//
//  TripResolver.swift
//  报销整理Native
//
//  行程分组算法（按交通票/酒店水单锚点 → 关联加油/餐饮/网约车）。
//  对应 core/trip_resolver.py:assign_trip / merge_trips_by_connectivity。
//
//  简化点：
//  - 移除 Python 用的 CITY_DICT（已删）
//  - 移除 EXCLUDE_CITIES 配置（用 isRealCity 启发式判断）
//  - 合并后实时更新所有 bill.targetSubdir
//

import Foundation

enum TripResolver {
    /// 锚点票据（能确定行程归属）
    private static let anchorTypes: Set<BillType> = [
        .trainTicket, .flightItinerary, .boardingPass,
        .hotelFolio, .hotelInvoice, .selfDriveSheet
    ]

    /// 非锚点（按时间就近归到 anchor 的 trip）
    private static let nonAnchorTypes: Set<BillType> = [
        .didiTrip, .didiInvoice, .gasInvoice, .tollInvoice,
        .dining, .telecom, .taxiTransport
    ]

    /// 主入口：bills → (trips, localBills)，同时把每个 bill 的 targetSubdir 填好
    static func assignTrips(bills: [BillInfo]) -> (trips: [TripGroup], local: [BillInfo]) {
        var anchors: [BillInfo] = []
        var nonAnchors: [BillInfo] = []
        for b in bills {
            if anchorTypes.contains(b.billType) { anchors.append(b) }
            else { nonAnchors.append(b) }
        }

        // 按首个 MMDD 排序
        anchors.sort { a, b in firstMMDD(of: a) < firstMMDD(of: b) }

        var groups: [TripGroup] = []
        for anchor in anchors {
            let first = firstMMDD(of: anchor)
            guard !first.isEmpty else {
                var a = anchor
                a.targetSubdir = "其他"
                continue
            }
            let last = lastMMDD(of: anchor, fallback: first)

            // 找 ≤3 天的现有 trip（按 index 访问以可变）
            var targetIdx: Int? = nil
            for (i, g) in groups.enumerated() {
                if absDateDiff(g.firstMMDD, first) <= 3 {
                    targetIdx = i; break
                }
            }
            if targetIdx == nil {
                groups.append(TripGroup(
                    key: "\(first)-\(last)",
                    firstMMDD: first,
                    lastMMDD: last
                ))
                targetIdx = groups.count - 1
            }
            if let idx = targetIdx {
                if first < groups[idx].firstMMDD { groups[idx].firstMMDD = first }
                if last > groups[idx].lastMMDD { groups[idx].lastMMDD = last }
                for c in anchor.cities where !groups[idx].cities.contains(c) {
                    groups[idx].cities.append(c)
                }
                var a = anchor
                a.targetSubdir = groups[idx].dirname
                groups[idx].bills.append(a)
            }
        }

        for non in nonAnchors {
            let mmdd = firstMMDD(of: non)
            if mmdd.isEmpty && (non.billType == .didiTrip || non.billType == .didiInvoice) {
                // 滴滴没日期 → 归第一个 trip
                if !groups.isEmpty {
                    var b = non
                    b.targetSubdir = groups[0].dirname
                    groups[0].bills.append(b)
                    continue
                }
            }
            if !mmdd.isEmpty {
                // 找最近的 trip（与 first/last 距离的最小值）
                var bestIdx: Int? = nil
                var bestDiff = 99
                for (i, g) in groups.enumerated() {
                    let d = min(absDateDiff(mmdd, g.firstMMDD), absDateDiff(mmdd, g.lastMMDD))
                    if d < bestDiff { bestIdx = i; bestDiff = d }
                }
                if let idx = bestIdx, bestDiff <= 5 {
                    var b = non
                    b.targetSubdir = groups[idx].dirname
                    groups[idx].bills.append(b)
                    continue
                }
            }
            var b = non
            b.targetSubdir = "本地"
        }

        // 通用化：合并日期相邻 + 城市连通的 trip
        groups = mergeByConnectivity(groups, maxGapDays: 5)

        // 重新刷一遍所有 bill.targetSubdir（merged 后 dirname 可能变了）
        for gi in 0..<groups.count {
            let dirname = groups[gi].dirname
            for bi in 0..<groups[gi].bills.count {
                groups[gi].bills[bi].targetSubdir = dirname
            }
        }

        let localBills = bills.filter { $0.targetSubdir == "本地" }
        return (groups, localBills)
    }

    // MARK: - 工具

    private static func firstMMDD(of bill: BillInfo) -> String {
        if let m = bill.dateMMDDs.first(where: { !$0.isEmpty }) { return String(m.prefix(4)) }
        if !bill.dateRange.start.isEmpty {
            // YYYY-MM-DD → MMDD
            return mmddFromDateString(bill.dateRange.start)
        }
        return ""
    }

    private static func lastMMDD(of bill: BillInfo, fallback: String) -> String {
        if !bill.dateRange.end.isEmpty {
            return mmddFromDateString(bill.dateRange.end)
        }
        if let m = bill.dateMMDDs.last(where: { !$0.isEmpty }) { return String(m.prefix(4)) }
        return fallback
    }

    /// YYYY-MM-DD → MMDD
    static func mmddFromDateString(_ s: String) -> String {
        guard s.count >= 10 else { return "" }
        let month = s.dropFirst(5).prefix(2)
        let day = s.dropFirst(8).prefix(2)
        return "\(month)\(day)"
    }

    /// 两个 MMDD 之间的天数差（同年内）
    static func absDateDiff(_ mmdd1: String, _ mmdd2: String) -> Int {
        guard mmdd1.count >= 4, mmdd2.count >= 4,
              let m1 = Int(mmdd1.prefix(2)), let d1 = Int(mmdd1.dropFirst(2).prefix(2)),
              let m2 = Int(mmdd2.prefix(2)), let d2 = Int(mmdd2.dropFirst(2).prefix(2)) else {
            return 99
        }
        let cal = Calendar.current
        let year = cal.component(.year, from: Date())
        guard let date1 = cal.date(from: DateComponents(year: year, month: m1, day: d1)),
              let date2 = cal.date(from: DateComponents(year: year, month: m2, day: d2)) else {
            return 99
        }
        return abs(cal.dateComponents([.day], from: date1, to: date2).day ?? 99)
    }

    /// 合并日期相邻 + 城市连通的 trip
    private static func mergeByConnectivity(_ groups: [TripGroup], maxGapDays: Int) -> [TripGroup] {
        guard groups.count >= 2 else { return groups }
        let sorted = groups.sorted { $0.firstMMDD < $1.firstMMDD }
        var merged: [TripGroup] = []
        for g in sorted {
            if merged.isEmpty { merged.append(g); continue }
            let lastIdx = merged.count - 1
            if absDateDiff(merged[lastIdx].lastMMDD, g.firstMMDD) > maxGapDays {
                merged.append(g); continue
            }
            // 城市连通
            let lastCities = Set(merged[lastIdx].cities.filter { merged[lastIdx].isRealCity($0) })
            let curCities = Set(g.cities.filter { g.isRealCity($0) })
            if lastCities.isEmpty || curCities.isEmpty || lastCities.isDisjoint(with: curCities) {
                merged.append(g); continue
            }
            // 合并
            merged[lastIdx].lastMMDD = max(merged[lastIdx].lastMMDD, g.lastMMDD)
            for c in g.cities where !merged[lastIdx].cities.contains(c) {
                merged[lastIdx].cities.append(c)
            }
            for b in g.bills {
                var bb = b
                bb.targetSubdir = merged[lastIdx].dirname
                merged[lastIdx].bills.append(bb)
            }
        }
        return merged
    }
}
