//
//  TripResolver.swift
//  报销整理Native
//
//  行程分组算法：以"常驻地"（EXCLUDE_CITIES）作为切分依据。
//
//  算法（按"从常驻地出发 → 回到常驻地"为一段行程）：
//  1. 按 fullDatePool 排序所有 anchor 票据（交通票 + 自驾行程单）
//     fullDatePool = 票据涉及的 **所有完整日期 yyyy-MM-dd**（跨年排序/合并正确）
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

    /// 锚点票据（能确定行程归属：交通票）
    /// 酒店水单/发票**不算 anchor**——它们就近归到 trip（≤7 天），
    /// 因为酒店发票只有 city、没有 from/to 城市，
    /// 把它当 anchor 会导致"酒店发票在两个 trip 之间 → 强行归前一段 → 影响 last 日期"。
    private static let anchorTypes: Set<BillType> = [
        .trainTicket, .flightItinerary, .boardingPass, .selfDriveSheet
    ]

    /// 主入口
    static func assignTrips(bills: [BillInfo], homeCities: Set<String>) -> (trips: [TripGroup], local: [BillInfo]) {
        var anchors: [BillInfo] = []
        var nonAnchors: [BillInfo] = []
        for b in bills {
            if anchorTypes.contains(b.billType) { anchors.append(b) }
            else { nonAnchors.append(b) }
        }

        // 按「所有相关完整日期」的最早者排序（跨年正确）
        anchors.sort { a, b in
            (fullDatePool(a).min() ?? "") < (fullDatePool(b).min() ?? "")
        }

        var groups: [TripGroup] = []
        var groupFirst: [String] = []   // 每段的完整起始日期（yyyy-MM-dd）
        var groupLast: [String] = []    // 每段的完整结束日期（yyyy-MM-dd）
        var currentIdx: Int? = nil
        var currentTripClosed = false
        var undatedAnchors: [BillInfo] = []

        for anchor in anchors {
            let aFirstFull = fullDatePool(anchor).min() ?? ""
            guard !aFirstFull.isEmpty else {
                // 无日期的交通票无法参与切分，但要保留到「本地」，避免整张消失
                undatedAnchors.append(anchor)
                continue
            }
            let aLastFull = fullDatePool(anchor).max() ?? aFirstFull

            let isHomeDeparture = isHomeCity(anchor.fromCity, in: homeCities)
            let isHomeArrival = isHomeCity(anchor.toCity, in: homeCities)

            // 决策（显式 if/else，避免 else-if 链短路）：
            //   - 第一个 anchor → 开新 trip
            //   - 当前 trip 未闭合 + to=home → 闭合当前 trip + 追加 anchor
            //   - 当前 trip 已闭合 + from=home → 开新 trip（出发新段）
            //   - 当前 trip 未闭合 + from=home → 拼到当前 trip（漏返程补充）
            //   - anchor 城市属于**之前某段 trip** → 归那个 trip（封闭后吸收）
            //   - 否则 → 开新 trip
            var startNew = false
            if currentIdx == nil {
                startNew = true
            } else if isHomeArrival && !currentTripClosed {
                // 闭合当前 trip + 把 anchor 归到当前 trip
                currentTripClosed = true
                startNew = false
            } else if isHomeDeparture {
                // closed=true 时 from=home → 开新 trip；否则是漏返程补充到当前 trip
                startNew = currentTripClosed
            } else {
                // 闭合 trip 不再无脑吸收 orphan：
                // 如果 anchor 的 from/to 城市**已经出现在某个 trip 的 cities 中** → 归那个 trip（补件）
                // 否则 → 开新 trip
                if currentTripClosed {
                    var matchedIdx: Int? = nil
                    for (i, g) in groups.enumerated() {
                        let tripCities = Set(g.cities.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
                        if !anchor.fromCity.isEmpty, tripCities.contains(anchor.fromCity.trimmingCharacters(in: .whitespaces).lowercased()),
                           matchedIdx == nil {
                            matchedIdx = i
                        }
                        if !anchor.toCity.isEmpty, tripCities.contains(anchor.toCity.trimmingCharacters(in: .whitespaces).lowercased()),
                           matchedIdx == nil {
                            matchedIdx = i
                        }
                    }
                    if let mIdx = matchedIdx {
                        // 命中任何一个 trip（含当前）：归那个 trip，补件
                        currentIdx = mIdx
                        currentTripClosed = false  // 重新激活（接受后续 anchor）
                        startNew = false
                    } else {
                        startNew = true  // 无任何 trip 命中 → 开新
                    }
                } else {
                    startNew = false
                }
            }

            if startNew {
                groups.append(TripGroup(
                    key: "\(mmddFromDateString(aFirstFull))-\(mmddFromDateString(aLastFull))",
                    firstMMDD: mmddFromDateString(aFirstFull),
                    lastMMDD: mmddFromDateString(aLastFull)
                ))
                groupFirst.append(aFirstFull)
                groupLast.append(aLastFull)
                currentIdx = groups.count - 1
                currentTripClosed = false
            }

            if let idx = currentIdx {
                // 用完整日期比较（跨年正确）扩展 trip 的 first/last
                if aFirstFull < groupFirst[idx] {
                    groupFirst[idx] = aFirstFull
                    groups[idx].firstMMDD = mmddFromDateString(aFirstFull)
                }
                if aLastFull > groupLast[idx] {
                    groupLast[idx] = aLastFull
                    groups[idx].lastMMDD = mmddFromDateString(aLastFull)
                }
                // 加 city（过滤常驻地）
                for c in anchor.cities {
                    if !groups[idx].cities.contains(c), !isHomeCity(c, in: homeCities) {
                        groups[idx].cities.append(c)
                    }
                }
                var a = anchor
                a.targetSubdir = groups[idx].dirname
                groups[idx].bills.append(a)
            }
        }

        // non-anchor：按「所有相关完整日期」就近归到 trip（≤7 天）
        var local: [BillInfo] = []
        for non in nonAnchors {
            guard let firstDate = fullDatePool(non).min() else {
                local.append(non)
                continue
            }
            var bestIdx: Int? = nil
            var bestDiff = Int.max
            for i in groups.indices {
                let d = min(fullDateDiff(firstDate, groupFirst[i]), fullDateDiff(firstDate, groupLast[i]))
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

        // 无日期的 anchor 落到「本地」，保证不丢
        for var u in undatedAnchors {
            u.targetSubdir = "本地"
            local.append(u)
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

    /// 该 bill 涉及的所有完整日期（yyyy-MM-dd，含年份，跨年排序/合并正确）
    /// 来源：dateRange（check_in/check_out 或 departure/issue）+ fields 里的日期字段，去重排序。
    static func fullDatePool(_ bill: BillInfo) -> [String] {
        var pool: [String] = []
        for d in [bill.dateRange.start, bill.dateRange.end] where d.count >= 10 {
            let s = String(d.prefix(10))
            if !pool.contains(s) { pool.append(s) }
        }
        for k in ["departure_date", "check_in_date", "check_out_date", "issue_date"] {
            if let v = bill.fields[k]?.flatMap({ $0 }), v.count >= 10 {
                let s = String(v.prefix(10))
                if !pool.contains(s) { pool.append(s) }
            }
        }
        return pool.sorted()
    }

    /// 两个完整日期（yyyy-MM-dd）之间的天数差（跨年精确）
    static func fullDateDiff(_ a: String, _ b: String) -> Int {
        guard a.count >= 10, b.count >= 10 else { return Int.max }
        func parse(_ s: String) -> (Int, Int, Int)? {
            guard let y = Int(s.prefix(4)),
                  let m = Int(s.dropFirst(5).prefix(2)),
                  let d = Int(s.dropFirst(8).prefix(2)) else { return nil }
            return (y, m, d)
        }
        guard let pa = parse(a), let pb = parse(b) else { return Int.max }
        let cal = Calendar(identifier: .gregorian)
        guard let da = cal.date(from: DateComponents(year: pa.0, month: pa.1, day: pa.2)),
              let db = cal.date(from: DateComponents(year: pb.0, month: pb.1, day: pb.2)) else { return Int.max }
        return abs(cal.dateComponents([.day], from: da, to: db).day ?? Int.max)
    }

    private static func isHomeCity(_ city: String, in home: Set<String>) -> Bool {
        home.contains(city.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// YYYY-MM-DD[THH:mm:ss] → MMDD
    /// 例：`2026-09-10` → `0910`、`2026-09-10T10:30:00` → `0910`
    static func mmddFromDateString(_ s: String) -> String {
        guard s.count >= 10 else { return "" }
        // 取索引 5..<10 的字符（必是 "MM-DD"），再去掉 "-"
        let idx = s.index(s.startIndex, offsetBy: 5)
        let endIdx = s.index(s.startIndex, offsetBy: 10)
        return s[idx..<endIdx].replacingOccurrences(of: "-", with: "")
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
        var diff = abs(cal.dateComponents([.day], from: date1, to: date2).day ?? 99)
        // 跨年启发式：同年内差距 >180 天，大概率是 12月↔1月 跨年；在 -1/0/+1 年的组合里取最小
        if diff > 180 {
            var best = diff
            for dy1 in -1...1 {
                for dy2 in -1...1 {
                    guard let a = cal.date(from: DateComponents(year: year + dy1, month: m1, day: d1)),
                          let b = cal.date(from: DateComponents(year: year + dy2, month: m2, day: d2)) else { continue }
                    best = min(best, abs(cal.dateComponents([.day], from: a, to: b).day ?? 99))
                }
            }
            diff = best
        }
        return diff
    }
}
