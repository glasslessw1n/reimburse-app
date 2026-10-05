//
//  StatusBadges.swift
//  报销整理Native
//
//  顶部状态区：OCR / LLM 为纯状态图标（不可点击），设置用独立齿轮按钮。
//

import SwiftUI

struct StatusBadges: View {
    @Environment(AppState.self) var state: AppState

    var body: some View {
        HStack(spacing: 10) {
            // OCR 状态（纯显示）
            StatusIcon(systemName: "text.viewfinder", ok: state.ocrAvailable, label: "OCR")

            // LLM 状态（纯显示）
            StatusIcon(systemName: "sparkles", ok: state.llmConfigured && state.llmAvailable, label: "LLM")

            // 设置齿轮按钮
            SettingsGearButton {
                state.showSettings = true
            }
        }
    }
}

/// 纯状态显示：图标 + 状态点（不可点击，hover 显示说明）
private struct StatusIcon: View {
    let systemName: String
    let ok: Bool
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Circle()
                .fill(ok ? Color.green : Color.gray.opacity(0.4))
                .frame(width: 6, height: 6)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.gray.opacity(0.08)))
        .help("\(label)：\(ok ? "可用" : "未就绪")")
    }
}

/// 设置齿轮按钮：hover 时齿轮转动并略微放大（尊重「减弱动态效果」）
private struct SettingsGearButton: View {
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(!reduceMotion && hovering ? 60 : 0))
                .scaleEffect(!reduceMotion && hovering ? 1.18 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: hovering)
        .help("LLM 设置")
    }
}
