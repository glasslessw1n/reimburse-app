//
//  FinalizeStep.swift
//  报销整理Native
//
//  行程归类结果：纵向列按 trip 分组的卡片
//  每张卡片显示：起始日期（MMDD-MMDD）+ 城市名 + 右侧总金额
//  对应 web 版的 tripsContainer 渲染
//

import SwiftUI

struct FinalizeStep: View {
    @Environment(AppState.self) var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            // 顶部摘要 + 补传按钮
            HStack {
                if let session = state.currentSession {
                    Text("\(session.manifest.trips.count) 个行程 · \(session.manifest.local.count) 项本地")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("补传") {
                    state.advance(to: .upload)
                }
                .buttonStyle(.bordered)
                .hoverLift()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)

            // 行程卡片列表
            ScrollView {
                LazyVStack(spacing: 12) {
                    if let session = state.currentSession {
                        ForEach(session.manifest.trips) { trip in
                            TripCard(trip: trip)
                        }
                        if !session.manifest.local.isEmpty {
                            LocalCard(bills: session.manifest.local)
                        }
                        if session.manifest.trips.isEmpty && session.manifest.local.isEmpty {
                            emptyHint
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .frame(maxHeight: .infinity)

            // 底部按钮
            HStack {
                Button("返回上传") {
                    state.advance(to: .upload)
                }
                .buttonStyle(.bordered)
                .hoverLift()

                Spacer()

                Button("下一步：打包 →") {
                    state.advance(to: .package)
                }
                .primaryAction()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
    }

    private var emptyHint: some View {
        ContentUnavailableView {
            Label("暂无可归类的票据", systemImage: "folder.badge.questionmark")
        } description: {
            Text("回到上传步骤补充票据")
        }
    }
}

/// 单个行程卡片（对应 web 版的 trip card）
private struct TripCard: View {
    let trip: TripGroup
    @State private var expanded = false

    private var totalAmount: Double {
        trip.bills.reduce(0) { $0 + $1.amount }
    }

    private var dateLabel: String {
        if trip.firstMMDD == trip.lastMMDD { return trip.firstMMDD }
        return "\(trip.firstMMDD)-\(trip.lastMMDD)"
    }

    private var cityLabel: String {
        // 拼接所有真实城市
        trip.cities
            .filter { $0.count <= 6 && !$0.contains(" ") }
            .reduce(into: [String]()) { acc, c in
                if acc.last != c { acc.append(c) }
            }
            .joined(separator: " ")
    }

    /// 未配对到发票的酒店水单数量（金额匹配）
    private var missingInvoiceCount: Int {
        let folios = trip.bills.filter { $0.billType == .hotelFolio }
        let invoices = trip.bills.filter { $0.billType == .hotelInvoice }
        var used = Set<Int>()
        var missing = 0
        for folio in folios {
            if let idx = invoices.indices.first(where: { i in
                !used.contains(i) && abs(invoices[i].amount - folio.amount) < 0.01
            }) {
                used.insert(idx)
            } else {
                missing += 1
            }
        }
        return missing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 卡片头部：左 = 日期 + 城市，右 = 金额
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(dateLabel)
                        .font(.system(size: 18, weight: .semibold).monospacedDigit())
                    if !cityLabel.isEmpty {
                        Text(cityLabel)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("未识别城市")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("¥")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        AnimatedNumber(value: totalAmount)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                    Text("\(trip.bills.count) 张")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if missingInvoiceCount > 0 {
                        Label("\(missingInvoiceCount) 段缺发票", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }
                }
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }

            // 展开的票据列表
            if expanded {
                Divider()
                VStack(spacing: 4) {
                    ForEach(trip.bills) { bill in
                        BillRow(bill: bill)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .background { VisualEffectView().clipShape(RoundedRectangle(cornerRadius: 10)).allowsHitTesting(false) }
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.gray.opacity(0.15), lineWidth: 0.5)
        )
    }
}

/// 本地卡片
private struct LocalCard: View {
    let bills: [BillInfo]
    @State private var expanded = false

    private var totalAmount: Double {
        bills.reduce(0) { $0 + $1.amount }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("本地")
                        .font(.system(size: 18, weight: .semibold))
                    Text("无法归入行程的本地票据")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("¥")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        AnimatedNumber(value: totalAmount)
                            .font(.system(size: 22, weight: .semibold))
                    }
                    Text("\(bills.count) 张")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }

            if expanded {
                Divider()
                VStack(spacing: 4) {
                    ForEach(bills) { bill in
                        BillRow(bill: bill)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .background { VisualEffectView().clipShape(RoundedRectangle(cornerRadius: 10)).allowsHitTesting(false) }
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.gray.opacity(0.15), lineWidth: 0.5)
        )
    }
}

#Preview {
    FinalizeStep()
        .environment(AppState())
}
