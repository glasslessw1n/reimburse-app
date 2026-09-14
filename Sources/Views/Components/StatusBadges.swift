//
//  StatusBadges.swift
//  报销整理Native
//
//  顶部状态徽章（OCR / LLM 可用性）。点击 LLM 徽章打开设置面板。
//

import SwiftUI

struct StatusBadges: View {
    @EnvironmentObject var state: AppState
    @State private var showSettings = false

    var body: some View {
        HStack(spacing: 8) {
            Badge(label: "OCR", ok: state.ocrAvailable)

            // LLM 徽章可点击 → 打开 Settings
            Button {
                showSettings = true
            } label: {
                Badge(label: "LLM", ok: state.llmConfigured && state.llmAvailable)
            }
            .buttonStyle(.plain)
            .help("点击配置 LLM")
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(state)
        }
    }
}

private struct Badge: View {
    let label: String
    let ok: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(ok ? Color.green : Color.gray.opacity(0.4))
                .frame(width: 6, height: 6)
            Text("\(label) \(ok ? "✓" : "—")")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(Color.gray.opacity(0.08))
        )
    }
}
