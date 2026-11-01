//
//  Preflight.swift
//  报销整理Native
//
//  提交前检查：打包前把会让财务退单/漏报的问题一次性列清。
//  配对口径与 Excel/整理页共用 finalize 的结果（pairedFolioUID、didiLetter），
//  金额口径与 ExcelBuilder 一致（滴滴子集和覆盖、酒店只计一次）。
//

import Foundation

struct PreflightItem: Identifiable, Sendable {
    enum Severity: Sendable { case error, warning, info }
    let severity: Severity
    let title: String
    let detail: String
    var id: String { title + "|" + detail }
}

struct PreflightReport: Sendable {
    var items: [PreflightItem] = []
    /// 分类合计（与 Excel 同口径）+ 总计
    var categoryTotals: [(name: String, amount: Double)] = []
    var grandTotal: Double = 0
    var errorCount: Int { items.filter { $0.severity == .error }.count }
    var warningCount: Int { items.filter { $0.severity == .warning }.count }
}

enum Preflight {

    static func check(session: SessionManager) -> PreflightReport {
        let manifest = session.manifest
        var report = PreflightReport()
        let originals = session.rootDir.appendingPathComponent("originals")

        // 1. 未完成整理：分组/配对都还没定，检查结论仅供参考
        if !manifest.finalized {
            report.items.append(.init(severity: .warning, title: "尚未完成整理",
                                      detail: "当前分组与配对基于未整理数据，请先在「整理」步完成整理再打包"))
        }

        // 2. 原文件缺失（打包会漏件）
        for bill in manifest.bills {
            let path = originals.appendingPathComponent(bill.sourceFile).path
            if !FileManager.default.fileExists(atPath: path) {
                report.items.append(.init(severity: .error, title: "原文件缺失",
                                          detail: "\(bill.sourceFile)（\(bill.billType.displayName)）不在 originals 中，打包将漏掉这张"))
            }
        }

        // 3. 待复核票据
        let reviewBills = manifest.bills.filter { $0.needsReview }
        for bill in reviewBills.prefix(20) {
            report.items.append(.init(severity: .warning, title: "待复核：\(bill.sourceFile)",
                                      detail: bill.reviewReason.isEmpty ? bill.billType.displayName : bill.reviewReason))
        }
        if reviewBills.count > 20 {
            report.items.append(.init(severity: .warning, title: "待复核共 \(reviewBills.count) 张",
                                      detail: "仅列出前 20 张，其余请在上传步逐张核对"))
        }

        // 按行程逐项检查配对（未整理时用现场分组兜底，结论已由上面的未整理提醒打折）
        let effectiveTrips: [TripGroup]
        let effectiveLocal: [BillInfo]
        if manifest.trips.isEmpty && manifest.local.isEmpty && !manifest.bills.isEmpty {
            let resolved = TripResolver.assignTrips(bills: manifest.bills, homeCities: Set(manifest.homeCities))
            effectiveTrips = resolved.trips
            effectiveLocal = resolved.local
        } else {
            effectiveTrips = manifest.trips
            effectiveLocal = manifest.local
        }
        let groups: [(name: String, bills: [BillInfo])] =
            effectiveTrips.map { ($0.dirname, $0.bills) } + (effectiveLocal.isEmpty ? [] : [("本地", effectiveLocal)])
        for group in groups {
            checkHotelPairs(group: group, into: &report)
            checkDidiPairs(group: group, into: &report)
        }

        // 4. 行程日期重叠（不同行程日期交叉，多半是分组切错）
        let ranges: [(name: String, start: String, end: String)] = effectiveTrips.compactMap { trip in
            let starts = trip.bills.map { $0.dateRange.start }.filter { $0.count >= 10 }
            let ends = trip.bills.map { $0.dateRange.end }.filter { $0.count >= 10 }
            guard let s = starts.min(), let e = ends.max() else { return nil }
            return (trip.dirname, s, e)
        }
        for i in ranges.indices {
            for j in (i + 1)..<ranges.count {
                if ranges[i].start <= ranges[j].end && ranges[j].start <= ranges[i].end {
                    report.items.append(.init(severity: .warning, title: "行程日期重叠",
                                              detail: "「\(ranges[i].name)」与「\(ranges[j].name)」日期交叉，请核对分组"))
                }
            }
        }

        // 5. 金额勾稽（与 Excel 同口径的分类合计）
        let totals = categoryTotals(trips: effectiveTrips, local: effectiveLocal)
        report.categoryTotals = totals
        report.grandTotal = totals.reduce(0) { $0 + $1.amount }

        if report.items.isEmpty {
            report.items.append(.init(severity: .info, title: "检查通过",
                                      detail: "未发现缺件、未配对或待复核问题"))
        }
        return report
    }

    // MARK: - 配对检查

    private static func checkHotelPairs(group: (name: String, bills: [BillInfo]), into report: inout PreflightReport) {
        let folios = group.bills.filter { $0.billType == .hotelFolio }
        let invoices = group.bills.filter { $0.billType == .hotelInvoice }
        guard !folios.isEmpty || !invoices.isEmpty else { return }

        if invoices.contains(where: { $0.pairedFolioUID != nil }) {
            let paired = Set(invoices.compactMap { $0.pairedFolioUID })
            for folio in folios where !paired.contains(folio.uid) {
                report.items.append(.init(severity: .warning, title: "\(group.name)：住宿缺发票",
                                          detail: "水单 \(folio.sourceFile)（¥\(fmt(folio.amount))）没有配对的住宿发票"))
            }
            let folioUIDs = Set(folios.map { $0.uid })
            for inv in invoices where !(inv.pairedFolioUID.map { folioUIDs.contains($0) } ?? false) {
                report.items.append(.init(severity: .info, title: "\(group.name)：发票未配对水单",
                                          detail: "发票 \(inv.sourceFile)（¥\(fmt(inv.amount))）没有对应水单，代订/只有发票时可忽略"))
            }
        } else {
            // 老清单无配对信息：金额回退判定
            var used = Set<Int>()
            for folio in folios {
                if let i = invoices.indices.first(where: { i in
                    !used.contains(i) && abs(invoices[i].amount - folio.amount) < 0.01
                }) {
                    used.insert(i)
                } else {
                    report.items.append(.init(severity: .warning, title: "\(group.name)：住宿缺发票",
                                              detail: "水单 \(folio.sourceFile)（¥\(fmt(folio.amount))）没有同额住宿发票"))
                }
            }
        }
    }

    private static func checkDidiPairs(group: (name: String, bills: [BillInfo]), into report: inout PreflightReport) {
        let trips = group.bills.filter { $0.billType == .didiTrip }
        let invoices = group.bills.filter { $0.billType == .didiInvoice }
        guard !trips.isEmpty || !invoices.isEmpty else { return }
        let tripLetters = Set(trips.map { $0.didiLetter }.filter { !$0.isEmpty })
        let invoiceLetters = Set(invoices.map { $0.didiLetter }.filter { !$0.isEmpty })
        for t in trips where !t.didiLetter.isEmpty && !invoiceLetters.contains(t.didiLetter) {
            report.items.append(.init(severity: .warning, title: "\(group.name)：滴滴行程单 \(t.didiLetter) 缺发票",
                                      detail: "\(t.sourceFile)（¥\(fmt(t.amount))）没有同字母的滴滴发票"))
        }
        for inv in invoices where !inv.didiLetter.isEmpty && !tripLetters.contains(inv.didiLetter) {
            report.items.append(.init(severity: .warning, title: "\(group.name)：滴滴发票 \(inv.didiLetter) 无行程单",
                                      detail: "\(inv.sourceFile)（¥\(fmt(inv.amount))）没有同字母的行程单"))
        }
    }

    // MARK: - 金额口径（与 ExcelBuilder 对齐）

    static func categoryTotals(trips: [TripGroup], local: [BillInfo]) -> [(name: String, amount: Double)] {
        var totals: [String: Double] = ["自驾车": 0, "交通": 0, "酒店": 0, "滴滴": 0, "餐饮": 0, "通信": 0, "其他": 0]
        let groups: [(bills: [BillInfo], isLocal: Bool)] =
            trips.map { ($0.bills, false) } + (local.isEmpty ? [] : [(local, true)])
        for (bills, isLocal) in groups {
            // 自驾车 = 加油 + 通行费
            totals["自驾车", default: 0] += bills.filter { $0.billType == .gasInvoice || $0.billType == .tollInvoice }
                .reduce(0) { $0 + max($1.amount, 0) }
            // 交通
            totals["交通", default: 0] += bills.filter { [.trainTicket, .flightItinerary, .boardingPass].contains($0.billType) }
                .reduce(0) { $0 + max($1.amount, 0) }
            // 酒店：水单全计 + 未配对发票（配对信息缺失时按金额回退）
            // 本地段与 Excel 一致：酒店水单/发票都归「其他」，不进酒店类
            let folios = isLocal ? [] : bills.filter { $0.billType == .hotelFolio }
            let invoices = isLocal ? [] : bills.filter { $0.billType == .hotelInvoice }
            totals["酒店", default: 0] += folios.reduce(0) { $0 + max($1.amount, 0) }
            if invoices.contains(where: { $0.pairedFolioUID != nil }) {
                let folioUIDs = Set(folios.map { $0.uid })
                totals["酒店", default: 0] += invoices
                    .filter { !($0.pairedFolioUID.map { folioUIDs.contains($0) } ?? false) }
                    .reduce(0) { $0 + max($1.amount, 0) }
            } else {
                var usedFolioAmounts = folios.map { $0.amount }
                for inv in invoices {
                    if let i = usedFolioAmounts.firstIndex(where: { abs($0 - inv.amount) < 0.01 }) {
                        usedFolioAmounts.remove(at: i)
                    } else {
                        totals["酒店", default: 0] += max(inv.amount, 0)
                    }
                }
            }
            // 滴滴：发票 + 未被子集和覆盖的行程单
            let didiTrips = bills.filter { $0.billType == .didiTrip }
            let didiInvoices = bills.filter { $0.billType == .didiInvoice }
            let covered = ExcelBuilder.didiCoveredTrips(
                invoiceAmounts: didiInvoices.map { $0.amount },
                tripAmounts: didiTrips.map { $0.amount })
            totals["滴滴", default: 0] += didiInvoices.reduce(0) { $0 + max($1.amount, 0) }
            totals["滴滴", default: 0] += didiTrips.indices
                .filter { !covered.contains($0) }
                .reduce(0) { $0 + max(didiTrips[$1].amount, 0) }
            // 餐饮 / 通信 / 其他
            totals["餐饮", default: 0] += bills.filter { $0.billType == .dining }.reduce(0) { $0 + max($1.amount, 0) }
            totals["通信", default: 0] += bills.filter { $0.billType == .telecom }.reduce(0) { $0 + max($1.amount, 0) }
            var handled: Set<BillType> = [.gasInvoice, .tollInvoice, .trainTicket, .flightItinerary, .boardingPass,
                                          .didiTrip, .didiInvoice, .dining, .telecom, .selfDriveSheet]
            if !isLocal { handled.formUnion([.hotelFolio, .hotelInvoice]) }
            totals["其他", default: 0] += bills.filter { !handled.contains($0.billType) }.reduce(0) { $0 + max($1.amount, 0) }
        }
        return ["自驾车", "交通", "酒店", "滴滴", "餐饮", "通信", "其他"].map { ($0, totals[$0] ?? 0) }
    }

    private static func fmt(_ v: Double) -> String {
        String(format: "%.2f", v)
    }
}
