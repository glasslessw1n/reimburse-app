//
//  TripResolver.swift
//  报销整理Native
//
//  行程分组算法：以"常驻地"（EXCLUDE_CITIES）作为切分依据。
//
//  算法（按"从常驻地出发 → 回到常驻地"为一段行程）：
//  1. 按 dateMMDDPool 排序所有 anchor 票据（交通票 + 酒店水单/发票 + 自驾行程单）
//     dateMMDDPool = 票据涉及的 **所有 MMDD**（合并 dateMMDDs 数组 + dateRange.start + dateRange.end 去重）
//  2. 扫一遍 anchor：
//     - 若 anchor 的 from_city 是常驻地 → 开新 trip（或拼到当前未闭合 trip）
//     - 若 anchor 的 to_city 是常驻地 → 闭合当前 trip
//     - 否则归当前 trip
//  3. 内部交通/酒店 → 归当前 trip（按时间最近 ≤7 天）
//  4. 行程目录 city 过滤掉常驻地
//
//  对应 core/trip_resolver.py 的 assign_trip。
//

import Foundation

enum TripResolver {

    /// 常驻地城市集合（小写比较）
    private static var homeCities: Set<String> = []

    /// 设置常驻地
    static func setHomeCities(_ cities: [String]) {
        homeCities = Set(cities.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
    }

    /// 锚点票据（能确定行程归属）
    private static let anchorTypes: Set<BillType> = [
        .trainTicket, .flightItinerary, .boardingPass,
        .hotelFolio, .hotelInvoice, .selfDriveSheet
    ]

    /// 主入口
    static func assignTrips(bills: [BillInfo]) -> (trips: [TripGroup], local: [BillInfo]) {
        var anchors: [BillInfo] = []
        var nonAnchors: [BillInfo] = []
        for b in bills {
            if anchorTypes.contains(b.billType) { anchors.append(b) }
            else { nonAnchors.append(b) }
        }

        // 按"所有相关日期"的最早者排序
        anchors.sort { a, b in
            let ap = dateMMDDPool(a)
            let bp = dateMMDDPool(b)
            return (ap.min() ?? "") < (bp.min() ?? "")
        }

        var groups: [TripGroup] = []
        var currentIdx: Int? = nil
        var currentTripClosed = false

        for anchor in anchors {
            let first = dateMMDDPool(anchor).min() ?? ""
            guard !first.isEmpty else { continue }

            let isHomeDeparture = isHomeCity(anchor.fromCity)
            let isHomeArrival = isHomeCity(anchor.toCity)
            let aFirst = dateMMDDPool(anchor).min() ?? first
            let aLast = dateMMDDPool(anchor).max() ?? first

            // 决策（用显式 if/else 避免 else-if 链短路 isHomeArrival）：
            //   - 第一个 anchor → 开新 trip
            //   - 当前 trip 未闭合 + to=home → 闭合当前 trip + 追加 anchor
            //   - 当前 trip 已闭合 + from=home → 开新 trip（出发新段）
            //   - 当前 trip 未闭合 + from=home → 拼到当前 trip（漏返程补充）
            //   - 否则 → 拼到当前 trip
            var startNew = false
            if currentIdx == nil {
                startNew = true
            } else if isHomeArrival && !currentTripClosed {
                // 闭合当前 trip + 把 anchor 归到当前 trip（这是返程票据）
                currentTripClosed = true
                startNew = false
            } else if isHomeDeparture {
                // 当前 trip 是否已闭合（上一段已返程）→ 出发新段；否则是漏返程补充
                startNew = currentTripClosed
            } else {
                startNew = false
            }

            if startNew {
                groups.append(TripGroup(
                    key: "\(aFirst)-\(aLast)",
                    firstMMDD: aFirst,
                    lastMMDD: aLast
                ))
                currentIdx = groups.count - 1
                currentTripClosed = false
            }

            if let idx = currentIdx {
                // 更新 trip 的 first/last（可能因 hotel check_out 扩展）
                if aFirst < groups[idx].firstMMDD { groups[idx].firstMMDD = aFirst }
                if aLast > groups[idx].lastMMDD { groups[idx].lastMMDD = aLast }
                // 加 city（过滤常驻地）
                for c in anchor.cities {
                    if !groups[idx].cities.contains(c), !isHomeCity(c) {
                        groups[idx].cities.append(c)
                    }
                }
                var a = anchor
                a.targetSubdir = groups[idx].dirname
                groups[idx].bills.append(a)
            }
        }

        // non-anchor：按"所有相关日期"就近归到 trip（≤7 天）
        var local: [BillInfo] = []
        for non in nonAnchors {
            let pool = dateMMDDPool(non)
            guard let firstDate = pool.min() else {
                local.append(non)
                continue
            }
            var bestIdx: Int? = nil
            var bestDiff = 999
            for (i, g) in groups.enumerated() {
                let d = min(absDateDiff(firstDate, g.firstMMDD), absDateDiff(firstDate, g.lastMMDD))
                if d < bestDiff { bestIdx = i; bestDiff = d }
            }
            if let idx = bestIdx, bestDiff <= 7 {
                var b = non
                b.targetSubdir = groups[idx].dirname
                groups[idx].bills.append(b)
            } else {
                var b = non
                b.targetSubdir = "本地"
                local.append(b)
            }
        }

        // 重新刷一遍所有 bill.targetSubdir（merged 后 dirname 可能变）
        for gi in 0..<groups.count {
            let dirname = groups[gi].dirname
            for bi in 0..<groups[gi].bills.count {
                groups[gi].bills[bi].targetSubdir = dirname
            }
        }

        return (groups, local)
    }

    // MARK: - 通用工具

    /// 该 bill 涉及的所有 MMDD（合并 dateMMDDs 数组 + dateRange.start + dateRange.end 去重）
    /// 关键：hotel folio/invoice 的 check_out_date 也会被纳入 → trip last 正确
    static func dateMMDDPool(_ bill: BillInfo) -> [String] {
        var pool: [String] = []
        // 1) dateMMDDs 数组（BillInfo 派生时已含 check_in + issue + check_out）
        for m in bill.dateMMDDs where !m.isEmpty {
            if !pool.contains(m) { pool.append(m) }
        }
        // 2) dateRange.start
        if !bill.dateRange.start.isEmpty {
            let m = mmddFromDateString(bill.dateRange.start)
            if !m.isEmpty, !pool.contains(m) { pool.append(m) }
        }
        // 3) dateRange.end
        if !bill.dateRange.end.isEmpty && bill.dateRange.end != bill.dateRange.start {
            let m = mmddFromDateString(bill.dateRange.end)
            if !m.isEmpty, !pool.contains(m) { pool.append(m) }
        }
        return pool.sorted()
    }

    private static func isHomeCity(_ city: String) -> Bool {
        homeCities.contains(city.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// YYYY-MM-DD → MMDD
    static func mmddFromDateString(_ s: String) -> String {
        guard s.count >= 10 else { return "" }
        return String(s.suffix(5).prefix(5)).replacingOccurrences(of: "-", with: "")
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
}
