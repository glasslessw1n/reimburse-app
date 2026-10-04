//
//  TripResolver.swift
//  报销整理Native
//
//  行程分组算法：以"常驻地"（EXCLUDE_CITIES）作为切分依据。
//
//  算法：
//  1. 按日期排序所有 anchor 票据（交通票 + 酒店水单/发票 + 自驾行程单）
//  2. 扫一遍 anchor，遇到以下情形开新 trip：
//     - 该 anchor 是从常驻地出发（from_city ∈ homeCities）
//     - 或该 anchor 是抵达常驻地（to_city ∈ homeCities）—— 当前 trip 已结束
//  3. 当前 trip 没结束时，所有 anchor / non-anchor 按时间顺序归入当前 trip
//  4. non-anchor（滴滴/餐饮/加油等）按时间就近归到对应 trip
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

        for anchor in anchors {
            let first = firstMMDD(of: anchor)
            guard !first.isEmpty else { continue }

            let isHomeDeparture = isHomeCity(anchor.fromCity)
            let isHomeArrival = isHomeCity(anchor.toCity)
            let isHotel = anchor.billType == .hotelFolio || anchor.billType == .hotelInvoice

            var shouldStartNewTrip = false
            if currentIdx == nil {
                // 第一个 anchor → 总开新 trip
                shouldStartNewTrip = true
            } else if let idx = currentIdx {
                // 当前已有 trip
                if isHomeArrival {
                    // 回到常驻地 → 当前 trip 结束（这个 anchor 归入新 trip 作为结束）
                    shouldStartNewTrip = true
                } else if isHomeDeparture {
                    // 从常驻地出发 → 当前 trip 已结束（上一个 trip 应该回常驻地，没回就当连续）
                    shouldStartNewTrip = true
                } else if isHotel {
                    // 酒店：归到当前 trip（不开新）
                    shouldStartNewTrip = false
                } else {
                    // 内部交通：归到当前 trip
                    shouldStartNewTrip = false
                }
                _ = idx
            }

            if shouldStartNewTrip {
                let last = lastMMDD(of: anchor, fallback: first)
                groups.append(TripGroup(
                    key: "\(first)-\(last)",
                    firstMMDD: first,
                    lastMMDD: last
                ))
                currentIdx = groups.count - 1
            }

            // 把 anchor 加进当前 trip
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

        // 把没分配到 trip 的 anchor 标记为"其他"
        for b in anchors {
            if b.targetSubdir.isEmpty {
                var bb = b
                bb.targetSubdir = "其他"
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
                // 滴滴无日期 → 归第一个 trip
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
