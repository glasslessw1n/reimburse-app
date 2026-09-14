//
//  WorkspaceView.swift
//  报销整理Native
//
//  四步工作流容器：upload / finalize / package
//  （识别结果直接显示在 UploadStep 拖放区下方，不再单独成 step）
//

import SwiftUI

struct WorkspaceView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            // 顶部：返回 + 状态徽章
            HStack(spacing: 12) {
                Button {
                    state.clearCurrentSession()
                    state.page = .home
                } label: {
                    Label("返回首页", systemImage: "chevron.left")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

                Spacer()

                StatusBadges()
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 8)

            // 步骤指示
            StepIndicator(current: state.workspaceStep) { step in
                state.advance(to: step)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            Divider()

            // 内容区
            Group {
                switch state.workspaceStep {
                case .upload:
                    UploadStep()
                case .finalize:
                    FinalizeStep()
                case .package:
                    PackageStep()
                default:
                    // .recognize 已合并到 upload，理论上不可达
                    UploadStep()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// 顶部步骤指示器
/// - 当前步骤：高亮（橙色填充）
/// - 已完成步骤：可点击回退（√ 图标 + 橙边）
/// - 未达步骤：灰色 muted
private struct StepIndicator: View {
    let current: WorkspaceStep
    let onSelect: (WorkspaceStep) -> Void

    /// 实际展示的步骤（去掉 recognize）
    private let displaySteps: [WorkspaceStep] = [.upload, .finalize, .package]

    private func isReached(_ step: WorkspaceStep) -> Bool {
        // 已完成 = 在当前之前
        return step.rawValue < current.rawValue
    }

    private func isCurrent(_ step: WorkspaceStep) -> Bool {
        return step == current
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(displaySteps.enumerated()), id: \.offset) { i, step in
                Button {
                    if isReached(step) || isCurrent(step) {
                        onSelect(step)
                    }
                } label: {
                    HStack(spacing: 6) {
                        ZStack {
                            Circle()
                                .fill(circleFill(step))
                                .frame(width: 22, height: 22)
                                .overlay(
                                    Circle()
                                        .stroke(circleStroke(step), lineWidth: isReached(step) ? 1 : 0)
                                )
                            if isReached(step) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(Color(red: 0.98, green: 0.36, blue: 0.10))
                            } else {
                                Text("\(i + 1)")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(isCurrent(step) ? .white : .secondary)
                            }
                        }
                        Text(step.title)
                            .font(.system(size: 12, weight: isCurrent(step) ? .semibold : .regular))
                            .foregroundColor(textColor(step))
                    }
                }
                .buttonStyle(.plain)
                .disabled(!isReached(step) && !isCurrent(step))
                .help(isReached(step) ? "返回\(step.title)" : step.title)

                if i < displaySteps.count - 1 {
                    Rectangle()
                        .fill(isReached(step) ? Color(red: 0.98, green: 0.36, blue: 0.10).opacity(0.4) : Color.gray.opacity(0.2))
                        .frame(height: 1)
                        .padding(.horizontal, 8)
                }
            }
        }
    }

    private func circleFill(_ step: WorkspaceStep) -> Color {
        if isCurrent(step) { return Color(red: 0.98, green: 0.36, blue: 0.10) }
        if isReached(step) { return Color(red: 0.98, green: 0.36, blue: 0.10).opacity(0.12) }
        return Color.gray.opacity(0.2)
    }

    private func circleStroke(_ step: WorkspaceStep) -> Color {
        if isReached(step) { return Color(red: 0.98, green: 0.36, blue: 0.10).opacity(0.5) }
        return .clear
    }

    private func textColor(_ step: WorkspaceStep) -> Color {
        if isCurrent(step) { return .primary }
        if isReached(step) { return Color(red: 0.98, green: 0.36, blue: 0.10) }
        return .secondary
    }
}

#Preview {
    WorkspaceView()
        .environmentObject(AppState())
}
