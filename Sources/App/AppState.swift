//
//  AppState.swift
//  报销整理Native
//
//  全局 ObservableObject：当前页面、LLM/OCR 可用性、会话状态、设置 store。
//

import SwiftUI
import Combine

/// 应用页面状态机
enum AppPage: Equatable {
    case home       // 首页
    case workspace  // 四步工作流
}

/// Workspace 内的步骤（3 步：上传 → 整理 → 打包）
/// 识别结果直接显示在 UploadStep 拖放区下方，不再单独成 step
enum WorkspaceStep: Int, CaseIterable, Equatable {
    case upload = 0
    case finalize = 1
    case package = 2

    var title: String {
        switch self {
        case .upload: return "上传"
        case .finalize: return "整理"
        case .package: return "打包"
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var page: AppPage = .home

    /// Workspace 内的步骤（每次新会话从 upload 开始）
    @Published var workspaceStep: WorkspaceStep = .upload

    /// 服务可用性
    @Published var ocrAvailable: Bool = true
    @Published var llmAvailable: Bool = false
    @Published var llmConfigured: Bool = false

    /// 当前 session
    @Published var currentSession: SessionManager?

    /// 全局设置
    let settingsStore = LLMSettingsStore()

    /// 启动时同步读 .env，并探测 LLM 是否真可用
    init() {
        settingsStore.loadIntoProcessEnv()
        llmConfigured = !settingsStore.settings.apiKey.isEmpty
        llmAvailable = llmConfigured  // TODO: 启动时 ping 一次
        ocrAvailable = TextExtractor.isAvailable
    }

    // MARK: - 会话管理

    /// 用户点"开始整理"时调
    func startNewSession() {
        let sid = Sessions.createNew()
        currentSession = SessionManager(sid: sid)
        workspaceStep = .upload
        page = .workspace
    }

    func clearCurrentSession() {
        currentSession = nil
        workspaceStep = .upload
    }

    // MARK: - 步骤切换

    func advance(to step: WorkspaceStep) {
        workspaceStep = step
    }
}
