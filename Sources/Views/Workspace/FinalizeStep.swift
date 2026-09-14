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
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            // 顶部摘要 + 补传按钮
            HStack {
                if let session = state.currentSession {
                    Text("\(session.manifest.trips.count) 个行程 · \(session.manifest.local.count) 项本地")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("补传") {
                    state.advance(to: .upload)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)

            Divider()

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

            Divider()

            // 底部按钮
            HStack {
                Button("返回上传") {
                    state.advance(to: .upload)
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("下一步：打包 →") {
                    state.advance(to: .package)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.98, green: 0.36, blue: 0.10))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 36))
                .foregroundColor(.gray.opacity(0.3))
            Text("暂无可归类的票据")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 60)
    }
}

/// 单个行程卡片（对应 web 版的 trip card）
private struct TripCard: View {
    let trip: TripGroup
    @State private var expanded = true

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
                            .foregroundColor(.secondary)
                    } else {
                        Text("未识别城市")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("¥")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Text(String(format: "%.2f", totalAmount))
                            .font(.system(size: 22, weight: .semibold).monospacedDigit())
                            .foregroundColor(.primary)
                    }
                    Text("\(trip.bills.count) 张")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
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
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.gray.opacity(0.15), lineWidth: 0.5)
        )
    }
}

/// 本地卡片
private struct LocalCard: View {
    let bills: [BillInfo]
    @State private var expanded = true

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
                        .foregroundColor(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("¥")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Text(String(format: "%.2f", totalAmount))
                            .font(.system(size: 22, weight: .semibold).monospacedDigit())
                    }
                    Text("\(bills.count) 张")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
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
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.gray.opacity(0.15), lineWidth: 0.5)
        )
    }
}

#Preview {
    FinalizeStep()
        .environmentObject(AppState())
}
