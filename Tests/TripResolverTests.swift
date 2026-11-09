//
//  TripResolverTests.swift
//  报销整理Native
//
//  覆盖 TripResolver 行程切分算法（Swift Testing 版）。
//
//  用例设计原则（针对"补丁 vs 整体"）：
//  - 每个用例聚焦**决策分支**（开新 / 闭合 / 拼接）
//  - 不用真实 LLM 输出，只构造 BillInfo 喂入
//  - 命名说明预期（"X→Y→Z 行程 包含 [A, B, C]"）
//

import Testing
@testable import 报销整理

struct TripResolverTests {

    /// 测试用常驻地（小写）
    private let homeCities: Set<String> = ["重庆", "成都"]

    // MARK: - 工具

    /// 以默认常驻地解析行程
    private func resolve(_ bills: [BillInfo]) -> (trips: [TripGroup], local: [BillInfo]) {
        TripResolver.assignTrips(bills: bills, homeCities: homeCities)
    }

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

    private func dumpTrips(_ groups: [TripGroup]) -> String {
        groups.enumerated().map { (i, g) in
            let bills = g.bills.map { "\($0.billType.rawValue)(\($0.sourceFile))" }.joined(separator: ", ")
            return "Trip[\(i)] \(g.key) cities=\(g.cities) bills=[\(bills)]"
        }.joined(separator: "\n")
    }

    // MARK: - 单元测试

    /// 1. 最简 happy path：重庆→厦门 登机牌 → 厦门酒店 → 厦门→重庆 登机牌
    ///    应切出 **1 段行程**，含 3 张 anchor
    @Test func singleTripHomeDepartureReturn() {
        let bills = [
            anchor(.boardingPass, from: "重庆", to: "厦门", date: "2026-09-10"),
            anchor(.hotelFolio,   from: "厦门", to: "厦门", date: "2026-09-10", endDate: "2026-09-12"),
            anchor(.boardingPass, from: "厦门", to: "重庆", date: "2026-09-12"),
        ]
        let r = resolve(bills)
        #expect(r.trips.count == 1, "应只切出 1 段行程\n\(dumpTrips(r.trips))")
        #expect(r.trips[0].bills.count == 3)
        #expect(r.trips[0].firstMMDD == "0910")
        #expect(r.trips[0].lastMMDD == "0912")
        // 城市应只剩厦门（home 重庆 被过滤）
        #expect(!r.trips[0].cities.contains(where: { $0.lowercased() == "重庆" }),
                "home city 不应在 cities 中：\(r.trips[0].cities)")
        #expect(r.trips[0].cities.contains("厦门"), "应包含厦门")
    }

    /// 2. 关键 bug 复现：0917-0918 福州住宿发票
    ///    现在应该归到 **下一个** 行程（0922 之后），而不是被错误归到上一段
    @Test func hotelInvoiceAttachesToFollowingTrip() {
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
        let r = resolve(bills)
        #expect(r.trips.count == 2, "应切出 2 段行程\n\(dumpTrips(r.trips))")
        // 第一段包含 2 张 boardingPass
        #expect(r.trips[0].bills.filter { $0.billType == .boardingPass }.count == 2)
        #expect(r.trips[0].lastMMDD == "0912")
        // 第二段应该把 0918 福州酒店发票带进来（≤7 天就近归到 Trip 2）
        let t2 = r.trips[1]
        #expect(t2.bills.contains { $0.billType == .hotelInvoice && $0.fields["issue_date"]?.flatMap { $0 } == "2026-09-18" },
                "0918 福州酒店发票应归到 Trip 2\n\(dumpTrips(r.trips))")
        // firstMMDD 由 anchor 决定，0918 是 non-anchor → 不影响 first
        #expect(t2.firstMMDD == "0922")
        #expect(t2.lastMMDD == "0924")
    }

    /// 3. 重要反向：trip 闭合后，**非 home 出发的 anchor** 应归当前 trip（"漏返程补充"）
    @Test func closedTripAbsorbsMissingReturn() {
        let bills = [
            anchor(.boardingPass, from: "重庆", to: "厦门", date: "2026-09-10"),
            anchor(.boardingPass, from: "厦门", to: "重庆", date: "2026-09-12"),
            // 已经闭合，后续 X→Y（非 home 出发）→ 拼到 Trip 0
            anchor(.trainTicket, from: "厦门", to: "福州", date: "2026-09-13"),
        ]
        let r = resolve(bills)
        #expect(r.trips.count == 1, "应只切出 1 段\n\(dumpTrips(r.trips))")
        #expect(r.trips[0].bills.count == 3)
        #expect(r.trips[0].lastMMDD == "0913")
    }

    /// 4. trip 闭合后，**home 出发的 anchor** → 开新 trip
    @Test func closedTripNewDepartureStartsNewTrip() {
        let bills = [
            anchor(.boardingPass, from: "重庆", to: "厦门", date: "2026-09-10"),
            anchor(.boardingPass, from: "厦门", to: "重庆", date: "2026-09-12"),
            // 新一段
            anchor(.boardingPass, from: "重庆", to: "北京", date: "2026-09-20"),
            anchor(.boardingPass, from: "北京", to: "重庆", date: "2026-09-22"),
        ]
        let r = resolve(bills)
        #expect(r.trips.count == 2, "应切出 2 段行程\n\(dumpTrips(r.trips))")
        #expect(r.trips[0].firstMMDD == "0910")
        #expect(r.trips[0].lastMMDD == "0912")
        #expect(r.trips[1].firstMMDD == "0920")
        #expect(r.trips[1].lastMMDD == "0922")
    }

    /// 5. trip 未闭合时，home 出发的 anchor（漏返程补充）→ 拼到当前 trip
    @Test func unclosedTripNewDepartureMerges() {
        let bills = [
            anchor(.boardingPass, from: "重庆", to: "厦门", date: "2026-09-10"),
            // 没返程，直接又是重庆出发（数据异常，但算法要 robust）
            anchor(.trainTicket, from: "重庆", to: "福州", date: "2026-09-15"),
        ]
        let r = resolve(bills)
        #expect(r.trips.count == 1)
        #expect(r.trips[0].bills.count == 2)
    }

    /// 6. 内部 X→Y（非 home 出发非 home 到达）→ 拼到当前 trip
    @Test func internalAnchorAttachesToCurrentTrip() {
        let bills = [
            anchor(.boardingPass, from: "重庆", to: "厦门", date: "2026-09-10"),
            anchor(.trainTicket, from: "厦门", to: "福州", date: "2026-09-11"),  // 内部跳转
            anchor(.boardingPass, from: "福州", to: "重庆", date: "2026-09-13"), // home 到达 → 闭合
        ]
        let r = resolve(bills)
        #expect(r.trips.count == 1)
        #expect(r.trips[0].bills.count == 3)
        #expect(r.trips[0].lastMMDD == "0913")
    }

    /// 6b. trip 已闭合后出现的 X→Y 内部 anchor（没有 home 出发/到达）
    ///     必须**不开新 trip**——closed 状态表示该 trip 已结束；后续应另开新段
    @Test func closedTripDoesNotAbsorbOrphanInternalAnchor() {
        let bills = [
            // Trip A: 0910-0912 重庆→厦门→重庆
            anchor(.boardingPass, from: "重庆", to: "厦门", date: "2026-09-10"),
            anchor(.boardingPass, from: "厦门", to: "重庆", date: "2026-09-12"),
            // Trip B 出发后才有 0915 trainTicket 内部跳转
            anchor(.boardingPass, from: "重庆", to: "广州", date: "2026-09-15"), // 开 Trip B
            anchor(.trainTicket, from: "广州", to: "深圳", date: "2026-09-15"), // 内部归 Trip B
        ]
        let r = resolve(bills)
        #expect(r.trips.count == 2)
        #expect(r.trips[0].lastMMDD == "0912")
        #expect(r.trips[1].bills.count == 2) // boardingPass 0915 + train 0915
    }

    /// 7. 酒店水单作为 non-anchor → 按 ≤7 天就近归到当前 trip
    @Test func hotelFolioCheckOutAttachesToTrip() {
        let bills = [
            anchor(.boardingPass, from: "重庆", to: "厦门", date: "2026-09-10"),
            anchor(.hotelFolio, from: "厦门", to: "厦门", date: "2026-09-10", endDate: "2026-09-13"),
            // 返程登机牌只到 0911
            anchor(.boardingPass, from: "厦门", to: "重庆", date: "2026-09-11"),
        ]
        let r = resolve(bills)
        #expect(r.trips.count == 1)
        // hotel folio 不再影响 first/last → last 由 anchor 决定 = 0911
        #expect(r.trips[0].lastMMDD == "0911")
        #expect(r.trips[0].bills.contains { $0.billType == .hotelFolio },
                "酒店水单应归到 Trip 0（≤7 天）")
    }

    /// 8. 非 anchor（dining/vat）按日期就近 ≤7 天归到 trip
    @Test func nonAnchorAttachesByDate() {
        let bills = [
            anchor(.boardingPass, from: "重庆", to: "厦门", date: "2026-09-10"),
            anchor(.boardingPass, from: "厦门", to: "重庆", date: "2026-09-12"),
            // 0915 餐饮（trip 已闭合）→ 应归 Trip 0
            anchor(.dining, date: "2026-09-15"),
        ]
        let r = resolve(bills)
        #expect(r.trips.count == 1)
        #expect(r.trips[0].bills.contains { $0.billType == .dining },
                "0915 dining 应归到 Trip 0（≤7 天）")
    }

    /// 9. 距离 > 7 天的非 anchor → 落到"本地"
    @Test func nonAnchorTooFarGoesToLocal() {
        let bills = [
            anchor(.boardingPass, from: "重庆", to: "厦门", date: "2026-09-10"),
            anchor(.boardingPass, from: "厦门", to: "重庆", date: "2026-09-12"),
            // 0930 dining（>7 天）→ 本地
            anchor(.dining, date: "2026-09-30"),
        ]
        let r = resolve(bills)
        #expect(r.trips.count == 1)
        #expect(r.local.count == 1)
        #expect(r.local[0].billType == .dining)
    }

    /// 10. 边界：空输入 → 0 trips
    @Test func emptyInput() {
        let r = resolve([])
        #expect(r.trips.count == 0)
        #expect(r.local.count == 0)
    }

    /// 11. 边界：全是 non-anchor → 全部落到"本地"
    @Test func allNonAnchors() {
        let bills = [
            anchor(.dining, date: "2026-09-10"),
            anchor(.other, date: "2026-09-15"),
        ]
        let r = resolve(bills)
        #expect(r.trips.count == 0)
        #expect(r.local.count == 2)
    }

    /// 12. 决策分支全覆盖——anchor 序列对每种 (currentClosed × fromIsHome × toIsHome) 都跑一遍
    @Test func decisionMatrixCoverage() {
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
        let r = resolve(bills)
        #expect(r.trips.count == 3, "应切出 3 段行程\n\(dumpTrips(r.trips))")
        #expect(r.trips[0].firstMMDD == "0910")
        #expect(r.trips[0].lastMMDD == "0913")
        #expect(r.trips[0].bills.count == 3)
        #expect(r.trips[1].firstMMDD == "0920")
        #expect(r.trips[1].lastMMDD == "0922")
        #expect(r.trips[1].bills.count == 3)
        #expect(r.trips[2].firstMMDD == "0925")
        #expect(r.trips[2].lastMMDD == "0926")
        #expect(r.trips[2].bills.count == 2)
    }

    /// 13. 酒店水单带发票（hotel_invoice）配对 → 都要归同一 trip
    @Test func hotelInvoiceAndFolioSameTrip() {
        let bills = [
            anchor(.boardingPass, from: "重庆", to: "厦门", date: "2026-09-10"),
            anchor(.hotelFolio,   from: "厦门", to: "厦门", date: "2026-09-10", endDate: "2026-09-12"),
            anchor(.hotelInvoice, from: "厦门", to: "厦门", date: "2026-09-12"),
            anchor(.boardingPass, from: "厦门", to: "重庆", date: "2026-09-12"),
        ]
        let r = resolve(bills)
        #expect(r.trips.count == 1)
        #expect(r.trips[0].bills.count == 4)
    }

    /// 14. mmddFromDateString 工具方法
    @Test func mmddFromDateString() {
        #expect(TripResolver.mmddFromDateString("2026-09-10") == "0910")
        #expect(TripResolver.mmddFromDateString("2026-09-10T10:30:00") == "0910")
        #expect(TripResolver.mmddFromDateString("") == "")
        #expect(TripResolver.mmddFromDateString("xxx") == "")
    }

    // 原 15/16（absDateDiff 工具方法）已随该无生产调用的死代码一并删除（四期清理）

    /// 17. 跨年行程：2025-12-30 出发 → 2026-01-02 返回，应合并为一段且 first/last 顺序正确
    @Test func crossYearTripOrdering() {
        let bills = [
            anchor(.boardingPass, from: "重庆", to: "厦门", date: "2025-12-30"),
            anchor(.boardingPass, from: "厦门", to: "重庆", date: "2026-01-02"),
        ]
        let r = resolve(bills)
        #expect(r.trips.count == 1, "跨年往返应合并为一段\n\(dumpTrips(r.trips))")
        #expect(r.trips[0].firstMMDD == "1230", "首日应为 12-30（跨年排序正确）\n\(dumpTrips(r.trips))")
        #expect(r.trips[0].lastMMDD == "0102", "末日应为 01-02\n\(dumpTrips(r.trips))")
    }

    /// 18. fullDateDiff 跨年精确天数
    @Test func fullDateDiffCrossYear() {
        #expect(TripResolver.fullDateDiff("2025-12-29", "2026-01-03") == 5)
        #expect(TripResolver.fullDateDiff("2026-01-03", "2025-12-29") == 5)
        #expect(TripResolver.fullDateDiff("2026-01-01", "2026-01-01") == 0)
    }

    /// 补件归到已闭合行程后，不应把该行程“重新打开”：
    /// 随后的 home 出发锚点必须开新段（旧实现会把整段新行程吞进旧行程）
    @Test func supplementDoesNotReopenClosedTrip() {
        let bills = [
            anchor(.boardingPass, from: "重庆", to: "厦门", date: "2026-09-10"),
            anchor(.boardingPass, from: "厦门", to: "重庆", date: "2026-09-12"),   // 闭合 Trip A
            anchor(.trainTicket, from: "厦门", to: "福州", date: "2026-09-13"),    // 补件 → 归 Trip A
            anchor(.boardingPass, from: "重庆", to: "北京", date: "2026-09-20"),   // 新一段出发
            anchor(.boardingPass, from: "北京", to: "重庆", date: "2026-09-22"),
        ]
        let r = resolve(bills)
        #expect(r.trips.count == 2, "补件不应重开已闭合行程\n\(dumpTrips(r.trips))")
        #expect(r.trips[0].bills.count == 3)
        #expect(r.trips[1].firstMMDD == "0920")
    }

    /// 长行程中部的酒店水单：日期区间与行程区间重叠即归属
    /// （旧实现只看与首尾端点距离，距首尾都 >7 天会被误放本地）
    @Test func midTripHotelAttachesByIntervalOverlap() {
        let bills = [
            anchor(.boardingPass, from: "重庆", to: "厦门", date: "2026-09-01"),
            anchor(.boardingPass, from: "厦门", to: "重庆", date: "2026-09-20"),
            BillInfo(billType: .hotelFolio, amount: 900, sourceFile: "folio.pdf",
                     fields: ["check_in_date": "2026-09-09", "check_out_date": "2026-09-11", "city": "厦门"]),
        ]
        let r = resolve(bills)
        #expect(r.trips.count == 1)
        #expect(r.trips[0].bills.contains { $0.billType == .hotelFolio },
                "行程中部的水单应归入行程\n\(dumpTrips(r.trips))")
        #expect(r.local.isEmpty)
    }

    // MARK: - 驻地优先（2026-11-09 新增）

    /// 万州行程的锚点对（重庆 ⇄ 万州，10-20 出发、10-22 返回）
    private func wanzhouAnchors() -> [BillInfo] {
        [
            anchor(.trainTicket, from: "重庆", to: "万州", date: "2026-10-20"),
            anchor(.trainTicket, from: "万州", to: "重庆", date: "2026-10-22"),
        ]
    }

    /// 驻地滴滴（起终点都在重庆）日期落在万州行程窗口内 → 归本地，不被日期吸进万州行程
    @Test func homeDidiTripGoesLocalDuringAwayTrip() {
        var bills = wanzhouAnchors()
        bills.append(anchor(.didiTrip, from: "重庆", to: "重庆", date: "2026-10-21", amount: 35))
        let r = resolve(bills)
        #expect(r.trips.count == 1)
        #expect(r.local.contains { $0.billType == .didiTrip },
                "重庆本地滴滴应归本地\n\(dumpTrips(r.trips)) local=\(r.local.map { $0.billType.rawValue })")
        #expect(!r.trips[0].bills.contains { $0.billType == .didiTrip })
    }

    /// 万州当地滴滴（城市为万州）→ 归万州行程；万州是独立地名，不算驻地
    @Test func awayDidiTripStaysInTrip() {
        var bills = wanzhouAnchors()
        bills.append(anchor(.didiTrip, from: "万州", to: "万州", date: "2026-10-21", amount: 28))
        let r = resolve(bills)
        #expect(r.trips[0].bills.contains { $0.billType == .didiTrip },
                "万州滴滴应归万州行程\n\(dumpTrips(r.trips))")
        #expect(!r.local.contains { $0.billType == .didiTrip })
    }

    /// 滴滴发票继承了行程单的驻地城市 → 跟随归本地
    @Test func linkedDidiInvoiceFollowsHomeTripToLocal() {
        var bills = wanzhouAnchors()
        bills.append(anchor(.didiInvoice, from: "重庆", to: "重庆", date: "2026-10-21", amount: 35))
        let r = resolve(bills)
        #expect(r.local.contains { $0.billType == .didiInvoice },
                "驻地滴滴发票应归本地\n\(dumpTrips(r.trips))")
    }

    /// 餐饮按开具地：开具地=驻地 → 本地；开具地=出差地 → 行程；无城市 → 回落日期归属
    @Test func diningAssignmentByIssueCity() {
        var bills = wanzhouAnchors()
        bills.append(BillInfo(billType: .dining, amount: 120, sourceFile: "d1.pdf",
                              fields: ["issue_date": "2026-10-21", "city": "重庆"]))
        bills.append(BillInfo(billType: .dining, amount: 88, sourceFile: "d2.pdf",
                              fields: ["issue_date": "2026-10-21", "city": "万州"]))
        bills.append(BillInfo(billType: .dining, amount: 66, sourceFile: "d3.pdf",
                              fields: ["issue_date": "2026-10-21"]))
        let r = resolve(bills)
        #expect(r.local.contains { $0.sourceFile == "d1.pdf" }, "重庆开具的餐饮应归本地")
        #expect(r.trips[0].bills.contains { $0.sourceFile == "d2.pdf" }, "万州开具的餐饮应归行程")
        #expect(r.trips[0].bills.contains { $0.sourceFile == "d3.pdf" }, "无城市的餐饮按日期归行程")
    }

    /// 城市规范化：「重庆市」与驻地「重庆」相等（通信发票开具地带「市」后缀）
    @Test func citySuffixNormalization() {
        var bills = wanzhouAnchors()
        bills.append(BillInfo(billType: .telecom, amount: 99, sourceFile: "t.pdf",
                              fields: ["issue_date": "2026-10-21", "city": "重庆市"]))
        let r = resolve(bills)
        #expect(r.local.contains { $0.billType == .telecom }, "「重庆市」应规范化后命中驻地")
    }

    // MARK: - 手动归类 override（2026-11-09 新增）

    /// override 到「本地」压过日期归属
    @Test func overrideToLocalBeatsDateAssignment() {
        var bills = wanzhouAnchors()
        var folio = BillInfo(billType: .hotelFolio, amount: 500, sourceFile: "f.pdf",
                             fields: ["check_in_date": "2026-10-20", "check_out_date": "2026-10-22", "city": "万州"])
        folio.groupOverride = "本地"
        bills.append(folio)
        let r = resolve(bills)
        #expect(r.local.contains { $0.billType == .hotelFolio }, "手动移到本地的水单应在本地")
        #expect(!r.trips[0].bills.contains { $0.billType == .hotelFolio })
    }

    /// override 到指定行程：日期上够不着的票据被手动归入该行程
    @Test func overrideToTripPullsDistantBill() {
        let base = wanzhouAnchors()
        let probe = resolve(base)
        let targetName = probe.trips[0].dirname
        var dining = BillInfo(billType: .dining, amount: 50, sourceFile: "far.pdf",
                              fields: ["issue_date": "2026-11-15"])
        dining.groupOverride = targetName
        let r = resolve(base + [dining])
        #expect(r.trips[0].bills.contains { $0.sourceFile == "far.pdf" },
                "手动指定行程的票据应进入该行程\n\(dumpTrips(r.trips))")
        #expect(!r.local.contains { $0.sourceFile == "far.pdf" })
    }

    /// override 目标行程不存在（dirname 已变）→ 保留自动归属，不丢票
    @Test func overrideToMissingTripFallsBackToAuto() {
        var bills = wanzhouAnchors()
        var dining = BillInfo(billType: .dining, amount: 60, sourceFile: "in.pdf",
                              fields: ["issue_date": "2026-10-21"])
        dining.groupOverride = "0101-0102 不存在"
        bills.append(dining)
        let r = resolve(bills)
        #expect(r.trips[0].bills.contains { $0.sourceFile == "in.pdf" },
                "目标行程不存在时应回落自动归属\n\(dumpTrips(r.trips))")
        #expect(r.trips.flatMap { $0.bills }.count + r.local.count == bills.count, "票据总数不应丢失")
    }
}
