//
//  AppState.swift
//  报销整理Native
//
//  全局 @Observable：当前页面、LLM/OCR 可用性、会话状态、设置 store。
//

import SwiftUI

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
@Observable
final class AppState {
    var page: AppPage = .home

    /// Workspace 内的步骤（每次新会话从 upload 开始）
    var workspaceStep: WorkspaceStep = .upload

    /// 服务可用性
    var ocrAvailable: Bool = true
    var llmAvailable: Bool = false
    var llmConfigured: Bool = false

    /// 当前 session
    var currentSession: SessionManager?

    /// 已保存的会话摘要（首页「最近会话」列表）
    var sessions: [SessionSummary] = []

    /// 是否弹出设置面板（供首页引导、状态徽章、⌘, 快捷键共用）
    var showSettings = false

    /// 全局设置
    let settingsStore = LLMSettingsStore()

    /// 启动时读 .env，并探测 LLM 是否真可用
    init() {
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

    /// 恢复一个已保存的会话；已整理过则直接进「整理」步骤，否则从上传开始
    func resumeSession(sid: String) {
        currentSession = SessionManager(sid: sid)
        if let s = currentSession {
            workspaceStep = (!s.manifest.trips.isEmpty || !s.manifest.local.isEmpty) ? .finalize : .upload
        } else {
            workspaceStep = .upload
        }
        page = .workspace
    }

    /// 刷新「最近会话」列表（首页出现时调）
    func refreshSessions() {
        sessions = Sessions.list()
    }

    /// 清空所有历史会话
    func clearHistory() {
        Sessions.clearAll()
        refreshSessions()
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
