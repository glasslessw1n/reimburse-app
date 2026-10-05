//
//  WorkspaceView.swift
//  报销整理Native
//
//  四步工作流容器：upload / finalize / package
//  （识别结果直接显示在 UploadStep 拖放区下方，不再单独成 step）
//
//  topbar 用系统 unified 工具栏：返回(左) + 步骤 segmented(中) + 状态徽章(右)
//

import SwiftUI

struct WorkspaceView: View {
    @Environment(AppState.self) var state: AppState

    var body: some View {
        @Bindable var state = state
        Group {
            switch state.workspaceStep {
            case .upload:
                UploadStep()
            case .finalize:
                FinalizeStep()
            case .package:
                PackageStep()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    state.clearCurrentSession()
                    state.page = .home
                } label: {
                    Label("返回首页", systemImage: "chevron.left")
                }
                .help("返回首页")
            }

            ToolbarItem(placement: .principal) {
                StepPicker(selection: $state.workspaceStep)
            }

            ToolbarItem(placement: .status) {
                StatusBadges()
            }
        }
    }
}

/// 步骤切换：segmented control（macOS 原生风格）
/// 只允许回退到已完成 / 前进 1 步，防止跳过中间步骤。
private struct StepPicker: View {
    @Binding var selection: WorkspaceStep

    var body: some View {
        Picker("步骤", selection: Binding(
            get: { selection },
            set: { new in
                if new.rawValue <= selection.rawValue + 1 {
                    selection = new
                }
            }
        )) {
            ForEach(WorkspaceStep.allCases, id: \.self) { step in
                Text(step.title).tag(step)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

#Preview {
    WorkspaceView()
        .environment(AppState())
}
