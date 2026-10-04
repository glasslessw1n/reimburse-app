//
//  TripResolverTests.swift
//  报销整理Native
//
//  覆盖 TripResolver 行程切分算法。
//
//  用例设计原则（针对"补丁 vs 整体"）：
//  - 每个用例聚焦**决策分支**（开新 / 闭合 / 拼接）
//  - 不用真实 LLM 输出，只构造 BillInfo 喂入
//  - 命名说明预期（"X→Y→Z 行程 包含 [A, B, C]"）
//

import XCTest
@testable import 报销整理

final class TripResolverTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TripResolver.setHomeCities(["重庆", "成都"])
    }

    // MARK: - 工具

    /// 构造一张 anchor BillInfo（覆盖关键字段）
    private func anchor(
        _ type: BillType,
        from: String = "",
        to: String = "",
        date: String = "",
        endDate: String = "",
        amount: Double = 0,
        cities: [String] = []
    ) -> BillInfo {
        var fields: [String: String?] = [:]
        if !date.isEmpty {
            fields["departure_date"] = .some(date)
            fields["check_in_date"] = .some(date)
            fields["issue_date"] = .some(date)
        }
        if !endDate.isEmpty {
            fields["check_out_date"] = .some(endDate)
        }
        if !from.isEmpty { fields["origin_city"] = .some(from) }
        if !to.isEmpty { fields["destination_city"] = .some(to) }
        let info = BillInfo(
            billType: type,
            amount: amount,
            sourceFile: "test.pdf",
            fields: fields
        )
        var withCities = info
        withCities.cities = cities.isEmpty ? [from, to].filter { !$0.isEmpty } : cities
        return withCities
    }

    /// 汇总每个 trip 的 (key, [billTypes])
    private func tripSummary(_ groups: [TripGroup]) -> [(String, [BillType])] {
        groups.map { ($0.key, $0.bills.map { $0.billType }) }
    }

    private func dumpTrips(_ groups: [TripGroup]) -> String {
        groups.enumerated().map { (i, g) in
            let bills = g.bills.map { "\($0.billType.rawValue)(\($0.sourceFile))" }.joined(separator: ", ")
            return "Trip[\(i)] \(g.key) cities=\(g.cities) bills=[\(bills)]"
        }.joined(separator: "\n")
    }

    // MARK: - 单元测试

    /// 1. 最简 happy path：重庆→厦门 登机牌 → 厦门酒店 → 厦门→重庆 登机牌
    ///    应切出 **1 段行程**，含 3 张 anchor
    func testSingleTripHomeDepartureReturn() {
        let bills = [
            anchor(.boardingPass, from: "重庆", to: "厦门", date: "2026-09-10"),
            anchor(.hotelFolio,   from: "厦门", to: "厦门", date: "2026-09-10", endDate: "2026-09-12"),
            anchor(.boardingPass, from: "厦门", to: "重庆", date: "2026-09-12"),
        ]
        let r = TripResolver.assignTrips(bills: bills)
        XCTAssertEqual(r.trips.count, 1, "应只切出 1 段行程\n\(dumpTrips(r.trips))")
        XCTAssertEqual(r.trips[0].bills.count, 3)
        XCTAssertEqual(r.trips[0].firstMMDD, "0910")
        XCTAssertEqual(r.trips[0].lastMMDD, "0912")
        // 城市应只剩厦门（home 重庆 被过滤）
        XCTAssertFalse(r.trips[0].cities.contains(where: { $0.lowercased() == "重庆" }),
                       "home city 不应在 cities 中：\(r.trips[0].cities)")
        XCTAssertTrue(r.trips[0].cities.contains("厦门"), "应包含厦门")
    }

    /// 2. 关键 bug 复现：0917-0918 福州住宿发票
    ///    现在应该归到 **下一个** 行程（0922 之后），而不是被错误归到上一段
    ///    简化版：构造两段行程，第二段的开头是福州酒店，没有交通 anchor
    func testHotelInvoiceAttachesToFollowingTrip() {
        let bills = [
            // Trip 1: 重庆→厦门→重庆 (0910-0912)
            anchor(.boardingPass, from: "重庆", to: "厦门", date: "2026-09-10"),
            anchor(.boardingPass, from: "厦门", to: "重庆", date: "2026-09-12"),
            // 福州住宿发票（只一张酒店发票，issue=0918，无交通）
            anchor(.hotelInvoice, from: "福州", to: "福州", date: "2026-09-18"),
            // Trip 2: 重庆→福州→重庆 (0922-0924)
            anchor(.boardingPass, from: "重庆", to: "福州", date: "2026-09-22"),
            anchor(.boardingPass, from: "福州", to: "重庆", date: "2026-09-24"),
        ]
        let r = TripResolver.assignTrips(bills: bills)
        XCTAssertEqual(r.trips.count, 2, "应切出 2 段行程\n\(dumpTrips(r.trips))")
        // 第一段包含 2 张 boardingPass
        XCTAssertEqual(r.trips[0].bills.filter { $0.billType == .boardingPass }.count, 2)
        XCTAssertEqual(r.trips[0].lastMMDD, "0912")
        // 第二段应该把 0918 福州酒店发票带进来（≤7 天就近归到 Trip 2）
        let t2 = r.trips[1]
        XCTAssertTrue(t2.bills.contains { $0.billType == .hotelInvoice && $0.fields["issue_date"]?.flatMap { $0 } == "2026-09-18" },
                      "0918 福州酒店发票应归到 Trip 2\n\(dumpTrips(r.trips))")
        // firstMMDD 由 anchor 决定，0918 是 non-anchor → 不影响 first
        XCTAssertEqual(t2.firstMMDD, "0922")
        XCTAssertEqual(t2.lastMMDD, "0924")
    }

    /// 3. 重要反向：trip 闭合后，**非 home 出发的 anchor** 应归当前 trip（"漏返程补充"）
    func testClosedTripAbsorbsMissingReturn() {
        let bills = [
            anchor(.boardingPass, from: "重庆", to: "厦门", date: "2026-09-10"),
            anchor(.boardingPass, from: "厦门", to: "重庆", date: "2026-09-12"),
            // 已经闭合，后续 X→Y（非 home 出发）→ 拼到 Trip 0
            anchor(.trainTicket, from: "厦门", to: "福州", date: "2026-09-13"),
        ]
        let r = TripResolver.assignTrips(bills: bills)
        XCTAssertEqual(r.trips.count, 1, "应只切出 1 段\n\(dumpTrips(r.trips))")
        XCTAssertEqual(r.trips[0].bills.count, 3)
        XCTAssertEqual(r.trips[0].lastMMDD, "0913")
    }

    /// 4. trip 闭合后，**home 出发的 anchor** → 开新 trip
    func testClosedTripNewDepartureStartsNewTrip() {
        let bills = [
            anchor(.boardingPass, from: "重庆", to: "厦门", date: "2026-09-10"),
            anchor(.boardingPass, from: "厦门", to: "重庆", date: "2026-09-12"),
            // 新一段
            anchor(.boardingPass, from: "重庆", to: "北京", date: "2026-09-20"),
            anchor(.boardingPass, from: "北京", to: "重庆", date: "2026-09-22"),
        ]
        let r = TripResolver.assignTrips(bills: bills)
        XCTAssertEqual(r.trips.count, 2, "应切出 2 段行程\n\(dumpTrips(r.trips))")
        XCTAssertEqual(r.trips[0].firstMMDD, "0910")
        XCTAssertEqual(r.trips[0].lastMMDD, "0912")
        XCTAssertEqual(r.trips[1].firstMMDD, "0920")
        XCTAssertEqual(r.trips[1].lastMMDD, "0922")
    }

    /// 5. trip 未闭合时，home 出发的 anchor（漏返程补充）→ 拼到当前 trip
    func testUnclosedTripNewDepartureMerges() {
        let bills = [
            anchor(.boardingPass, from: "重庆", to: "厦门", date: "2026-09-10"),
            // 没返程，直接又是重庆出发（数据异常，但算法要 robust）
            anchor(.trainTicket, from: "重庆", to: "福州", date: "2026-09-15"),
        ]
        let r = TripResolver.assignTrips(bills: bills)
        XCTAssertEqual(r.trips.count, 1)
        XCTAssertEqual(r.trips[0].bills.count, 2)
    }

    /// 6. 内部 X→Y（非 home 出发非 home 到达）→ 拼到当前 trip
    func testInternalAnchorAttachesToCurrentTrip() {
        let bills = [
            anchor(.boardingPass, from: "重庆", to: "厦门", date: "2026-09-10"),
            anchor(.trainTicket, from: "厦门", to: "福州", date: "2026-09-11"),  // 内部跳转
            anchor(.boardingPass, from: "福州", to: "重庆", date: "2026-09-13"), // home 到达 → 闭合
        ]
        let r = TripResolver.assignTrips(bills: bills)
        XCTAssertEqual(r.trips.count, 1)
        XCTAssertEqual(r.trips[0].bills.count, 3)
        XCTAssertEqual(r.trips[0].lastMMDD, "0913")
    }

    /// 7. 酒店水单作为 non-anchor → 按 ≤7 天就近归到当前 trip
    ///    （不再是 anchor → 不会影响 trip 的 first/last）
    func testHotelFolioCheckOutAttachesToTrip() {
        let bills = [
            anchor(.boardingPass, from: "重庆", to: "厦门", date: "2026-09-10"),
            anchor(.hotelFolio, from: "厦门", to: "厦门", date: "2026-09-10", endDate: "2026-09-13"),
            // 返程登机牌只到 0911
            anchor(.boardingPass, from: "厦门", to: "重庆", date: "2026-09-11"),
        ]
        let r = TripResolver.assignTrips(bills: bills)
        XCTAssertEqual(r.trips.count, 1)
        // hotel folio 不再影响 first/last → last 由 anchor 决定 = 0911
        XCTAssertEqual(r.trips[0].lastMMDD, "0911")
        XCTAssertTrue(r.trips[0].bills.contains { $0.billType == .hotelFolio },
                      "酒店水单应归到 Trip 0（≤7 天）")
    }

    /// 8. 非 anchor（dining/vat）按日期就近 ≤7 天归到 trip
    func testNonAnchorAttachesByDate() {
        let bills = [
            anchor(.boardingPass, from: "重庆", to: "厦门", date: "2026-09-10"),
            anchor(.boardingPass, from: "厦门", to: "重庆", date: "2026-09-12"),
            // 0915 餐饮（trip 已闭合）→ 应归 Trip 0
            anchor(.dining, date: "2026-09-15"),
        ]
        let r = TripResolver.assignTrips(bills: bills)
        XCTAssertEqual(r.trips.count, 1)
        XCTAssertTrue(r.trips[0].bills.contains { $0.billType == .dining },
                      "0915 dining 应归到 Trip 0（≤7 天）")
    }

    /// 9. 距离 > 7 天的非 anchor → 落到"本地"
    func testNonAnchorTooFarGoesToLocal() {
        let bills = [
            anchor(.boardingPass, from: "重庆", to: "厦门", date: "2026-09-10"),
            anchor(.boardingPass, from: "厦门", to: "重庆", date: "2026-09-12"),
            // 0930 dining（>7 天）→ 本地
            anchor(.dining, date: "2026-09-30"),
        ]
        let r = TripResolver.assignTrips(bills: bills)
        XCTAssertEqual(r.trips.count, 1)
        XCTAssertEqual(r.local.count, 1)
        XCTAssertEqual(r.local[0].billType, .dining)
    }

    /// 10. 边界：空输入 → 0 trips
    func testEmptyInput() {
        let r = TripResolver.assignTrips(bills: [])
        XCTAssertEqual(r.trips.count, 0)
        XCTAssertEqual(r.local.count, 0)
    }

    /// 11. 边界：全是 non-anchor → 全部落到"本地"
    func testAllNonAnchors() {
        let bills = [
            anchor(.dining, date: "2026-09-10"),
            anchor(.vatInvoiceGeneral, date: "2026-09-15"),
        ]
        let r = TripResolver.assignTrips(bills: bills)
        XCTAssertEqual(r.trips.count, 0)
        XCTAssertEqual(r.local.count, 2)
    }

    /// 12. 决策分支全覆盖——anchor 序列对每种 (currentClosed × fromIsHome × toIsHome)
    ///     都跑一遍，确保 else-if 链正确
    ///     算法：第一个 anchor 开新 trip；to=home 且未闭合 → 闭合；从 home 出发且已闭合 → 开新；
    ///           其他 → 拼到当前 trip
    func testDecisionMatrixCoverage() {
        let bills = [
            // Trip A: 0910-0915 厦门福州往返
            anchor(.boardingPass, from: "重庆", to: "厦门", date: "2026-09-10"), // (首) startNew=true
            anchor(.trainTicket,  from: "厦门", to: "福州", date: "2026-09-11"), // 内部
            anchor(.boardingPass, from: "福州", to: "重庆", date: "2026-09-13"), // 闭合 trip A
            // 0920 从 home 出发（trip A 已闭合）→ 开 Trip B
            anchor(.boardingPass, from: "重庆", to: "北京", date: "2026-09-20"), // 新段
            anchor(.trainTicket,  from: "北京", to: "天津", date: "2026-09-21"), // 内部
            anchor(.boardingPass, from: "天津", to: "重庆", date: "2026-09-22"), // 闭合 trip B
            // Trip C: 0925-0926 上海往返
            anchor(.trainTicket,  from: "重庆", to: "上海", date: "2026-09-25"), // 新段
            anchor(.boardingPass, from: "上海", to: "重庆", date: "2026-09-26"), // 闭合
        ]
        let r = TripResolver.assignTrips(bills: bills)
        XCTAssertEqual(r.trips.count, 3, "应切出 3 段行程\n\(dumpTrips(r.trips))")
        // 注意：TripGroup.key 在创建时就被冻结，但 dirname 用 first/lastMMDD 实时计算
        XCTAssertEqual(r.trips[0].firstMMDD, "0910")
        XCTAssertEqual(r.trips[0].lastMMDD, "0913")
        XCTAssertEqual(r.trips[0].bills.count, 3)
        XCTAssertEqual(r.trips[1].firstMMDD, "0920")
        XCTAssertEqual(r.trips[1].lastMMDD, "0922")
        XCTAssertEqual(r.trips[1].bills.count, 3)
        XCTAssertEqual(r.trips[2].firstMMDD, "0925")
        XCTAssertEqual(r.trips[2].lastMMDD, "0926")
        XCTAssertEqual(r.trips[2].bills.count, 2)
    }

    /// 13. 酒店水单带发票（hotel_invoice）配对 → 都要归同一 trip
    func testHotelInvoiceAndFolioSameTrip() {
        let bills = [
            anchor(.boardingPass, from: "重庆", to: "厦门", date: "2026-09-10"),
            anchor(.hotelFolio,   from: "厦门", to: "厦门", date: "2026-09-10", endDate: "2026-09-12"),
            anchor(.hotelInvoice, from: "厦门", to: "厦门", date: "2026-09-12"),
            anchor(.boardingPass, from: "厦门", to: "重庆", date: "2026-09-12"),
        ]
        let r = TripResolver.assignTrips(bills: bills)
        XCTAssertEqual(r.trips.count, 1)
        XCTAssertEqual(r.trips[0].bills.count, 4)
    }

    /// 14. mmddFromDateString 工具方法
    func testMmddFromDateString() {
        XCTAssertEqual(TripResolver.mmddFromDateString("2026-09-10"), "0910")
        XCTAssertEqual(TripResolver.mmddFromDateString("2026-09-10T10:30:00"), "0910")
        XCTAssertEqual(TripResolver.mmddFromDateString(""), "")
        XCTAssertEqual(TripResolver.mmddFromDateString("xxx"), "")
    }

    /// 15. absDateDiff 工具方法
    func testAbsDateDiff() {
        XCTAssertEqual(TripResolver.absDateDiff("0901", "0910"), 9)
        XCTAssertEqual(TripResolver.absDateDiff("0910", "0901"), 9)
        XCTAssertEqual(TripResolver.absDateDiff("0910", "1010"), 30)
    }
}
