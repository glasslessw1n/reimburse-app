//
//  BillRow.swift
//  报销整理Native
//
//  单条票据行：类型徽章 + 标题 + 金额 + 详情展开。
//

import SwiftUI

struct BillRow: View {
    let bill: BillInfo
    @State private var expanded = false

    /// 颜色对应 web 版 .transport / .ride / .hotel / .invoice / .fuel / .misc / .other
    var typeColor: Color {
        switch bill.billType.cssClass {
        case "transport": return Color.blue
        case "ride": return Color.indigo
        case "hotel": return Color.purple
        case "invoice": return Color.orange
        case "fuel": return Color.teal
        case "misc": return Color.pink
        default: return Color.gray
        }
    }

    var headline: String {
        switch bill.billType {
        case .trainTicket:
            return "\(bill.fromCity.isEmpty ? "?" : bill.fromCity) → \(bill.toCity.isEmpty ? "?" : bill.toCity)"
        case .flightItinerary, .boardingPass:
            return "\(bill.fromCity.isEmpty ? "?" : bill.fromCity) → \(bill.toCity.isEmpty ? "?" : bill.toCity)"
        case .hotelFolio, .hotelInvoice:
            return bill.fields["hotel_name"]?.flatMap { $0 } ?? bill.fields["seller_name"]?.flatMap { $0 } ?? "酒店"
        case .didiTrip:
            return "滴滴行程"
        case .didiInvoice:
            return "滴滴发票"
        case .vatInvoiceGeneral, .vatInvoiceSpecial:
            return bill.fields["seller_name"]?.flatMap { $0 } ?? "发票"
        case .gasInvoice:
            return bill.fields["merchant_name"]?.flatMap { $0 } ?? "加油"
        case .tollInvoice:
            return "通行费"
        case .dining:
            return bill.fields["merchant_name"]?.flatMap { $0 } ?? "餐饮"
        case .telecom:
            return bill.fields["carrier"]?.flatMap { $0 } ?? "通信"
        case .selfDriveSheet:
            return "\(bill.fromCity.isEmpty ? "?" : bill.fromCity) → \(bill.toCity.isEmpty ? "?" : bill.toCity)"
        case .taxiTransport:
            return bill.fields["merchant_name"]?.flatMap { $0 } ?? "出租"
        case .other:
            return bill.fields["merchant_name"]?.flatMap { $0 } ?? bill.sourceFile
        }
    }

    var subtitle: String {
        let date = displayDate(bill)
        let confStr = String(format: "%.0f%%", bill.confidence * 100)
        if bill.needsReview {
            return "\(date) · ⚠️ 需要确认"
        }
        return "\(date) · 置信度 \(confStr)"
    }

    private func displayDate(_ bill: BillInfo) -> String {
        // 优先 dateRange.start（MMDD），退化到 sourceFile
        if !bill.dateRange.start.isEmpty {
            let s = bill.dateRange.start
            if s.count >= 10 {
                return String(s.dropFirst(5).prefix(5))   // 03-15
            }
        }
        if let m = bill.dateMMDDs.first(where: { !$0.isEmpty }) {
            return String(m.prefix(4)).mmdd()  // 0315 → 03-15
        }
        return bill.sourceFile
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // 类型徽章
                Text(bill.billType.displayName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(typeColor)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Text(String(format: "¥%.2f", bill.amount))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundColor(.primary)

                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            }

            if expanded {
                Divider()
                detailContent
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.gray.opacity(0.03))
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.gray.opacity(0.15), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var detailContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(bill.fields.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                if let v = value, !v.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Text(key)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .frame(width: 100, alignment: .leading)
                        Text(v)
                            .font(.system(size: 11))
                            .foregroundColor(.primary)
                            .textSelection(.enabled)
                        Spacer()
                    }
                }
            }
            if !bill.error.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                        .font(.system(size: 11))
                    Text(bill.error)
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                }
            }
        }
    }
}

private extension String {
    /// "0315" → "03-15"
    func mmdd() -> String {
        guard count >= 4 else { return self }
        let m = self.prefix(2)
        let d = self.dropFirst(2).prefix(2)
        return "\(m)-\(d)"
    }
}
