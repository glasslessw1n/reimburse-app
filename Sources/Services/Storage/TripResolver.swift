//
//  TripResolver.swift
//  报销整理Native
//
//  行程分组算法：以"常驻地"（EXCLUDE_CITIES）作为切分依据。
//
//  算法（按"从常驻地出发 → 回到常驻地"为一段行程）：
//  1. 按日期排序所有 anchor 票据（交通票 + 酒店水单/发票 + 自驾行程单）
//  2. 扫一遍 anchor：
//     - 若 from_city ∈ homeCities（从常驻地出发）→ 开新 trip
//     - 若 to_city ∈ homeCities（回到常驻地）→ 当前 trip 结束（这个 anchor 归当前 trip）
//     - 酒店、内部交通 → 归当前 trip
//  3. 内部循环：一个 trip 内可能有多段（厦门→重庆→广州→深圳→梅州→潮汕→福州→重庆 = 整个 trip 2）
//
//  对应 core/trip_resolver.py 的 assign_trip，但用 EXCLUDE_CITIES 切分代替 CITY_DICT 启发式。
//

import Foundation

enum TripResolver {

    /// 常驻地城市集合（小写比较，去前/后空格）
    /// 由 SessionManager.finalize() 在调用 assignTrips 前注入
    private static var homeCities: Set<String> = []

    /// 设置常驻地（外部在调 assignTrips 之前调用）
    static func setHomeCities(_ cities: [String]) {
        homeCities = Set(cities.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
    }

    /// 锚点票据（能确定行程归属）
    private static let anchorTypes: Set<BillType> = [
        .trainTicket, .flightItinerary, .boardingPass,
        .hotelFolio, .hotelInvoice, .selfDriveSheet
    ]

    /// 主入口：bills → (trips, localBills)
    static func assignTrips(bills: [BillInfo]) -> (trips: [TripGroup], local: [BillInfo]) {
        var anchors: [BillInfo] = []
        var nonAnchors: [BillInfo] = []
        for b in bills {
            if anchorTypes.contains(b.billType) { anchors.append(b) }
            else { nonAnchors.append(b) }
        }
        anchors.sort { a, b in firstMMDD(of: a) < firstMMDD(of: b) }

        var groups: [TripGroup] = []
        var currentIdx: Int? = nil
        var currentTripClosed = false   // 当前 trip 是否已经收到 from=home 或 to=home 对从而闭合

        for anchor in anchors {
            let first = firstMMDD(of: anchor)
            guard !first.isEmpty else { continue }

            let isHomeDeparture = isHomeCity(anchor.fromCity)
            let isHomeArrival = isHomeCity(anchor.toCity)

            // 决策：
            //   - 第一个 anchor → 开新 trip
            //   - 当前 trip 已闭合（任何 anchor）→ 开新 trip
            //   - 当前 trip 未闭合 + from=home → 这是上一段漏了返程，把它归到当前 trip
            //   - 当前 trip 未闭合 + to=home → 闭合当前 trip
            //   - 否则归当前 trip
            var startNew = false
            if currentIdx == nil {
                startNew = true
            } else if currentTripClosed {
                // 上一段已闭合（收到返程）→ 不管下一个 anchor 是什么，都开新 trip
                startNew = true
            } else if isHomeDeparture {
                // 未闭合但 anchor 是 from=home → 是上一段漏了返程的补充，归到当前 trip
                startNew = false
            } else if isHomeArrival {
                // 收到返程 → 当前 trip 闭合
                currentTripClosed = true
            }

            if startNew {
                let last = lastMMDD(of: anchor, fallback: first)
                groups.append(TripGroup(
                    key: "\(first)-\(last)",
                    firstMMDD: first,
                    lastMMDD: last
                ))
                currentIdx = groups.count - 1
                currentTripClosed = false
            }

            if let idx = currentIdx {
                if first < groups[idx].firstMMDD { groups[idx].firstMMDD = first }
                let aLast = lastMMDD(of: anchor, fallback: first)
                if aLast > groups[idx].lastMMDD { groups[idx].lastMMDD = aLast }
                for c in anchor.cities where !groups[idx].cities.contains(c) {
                    groups[idx].cities.append(c)
                }
                var a = anchor
                a.targetSubdir = groups[idx].dirname
                groups[idx].bills.append(a)
            }
        }

        // non-anchor：按时间就近归到最近的 trip（≤7 天）
        for non in nonAnchors {
            let mmdd = firstMMDD(of: non)
            var bestIdx: Int? = nil
            var bestDiff = 99
            if !mmdd.isEmpty {
                for (i, g) in groups.enumerated() {
                    let d = min(absDateDiff(mmdd, g.firstMMDD), absDateDiff(mmdd, g.lastMMDD))
                    if d < bestDiff { bestIdx = i; bestDiff = d }
                }
            } else if non.billType == .didiTrip || non.billType == .didiInvoice {
                if !groups.isEmpty { bestIdx = 0; bestDiff = 0 }
            }
            if let idx = bestIdx, bestDiff <= 7 {
                var b = non
                b.targetSubdir = groups[idx].dirname
                groups[idx].bills.append(b)
            } else {
                var b = non
                b.targetSubdir = "本地"
            }
        }

        // 重新刷一遍所有 bill.targetSubdir
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

    private static func isHomeCity(_ city: String) -> Bool {
        homeCities.contains(city.trimmingCharacters(in: .whitespaces).lowercased())
    }

    private static func firstMMDD(of bill: BillInfo) -> String {
        if let m = bill.dateMMDDs.first(where: { !$0.isEmpty }) { return String(m.prefix(4)) }
        if !bill.dateRange.start.isEmpty {
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
}
