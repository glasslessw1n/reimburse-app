//
//  ReviewBadge.swift
//  报销整理Native
//
//  「需确认」提醒徽章（借鉴 RareUI「Notification bell」，出现时轻微弹入）。
//

import SwiftUI

struct ReviewBadge: View {
    let count: Int

    @State private var appeared = false

    var body: some View {
        Label("\(count) 张需确认", systemImage: "exclamationmark.triangle")
            .font(.system(size: 11))
            .foregroundStyle(.orange)
            .scaleEffect(appeared ? 1.0 : 0.5)
            .animation(.spring(response: 0.4, dampingFraction: 0.5), value: appeared)
            .onAppear { appeared = true }
    }
}

#Preview {
    ReviewBadge(count: 3)
}
