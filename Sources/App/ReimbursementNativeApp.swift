//
//  ReimbursementNativeApp.swift
//  报销整理Native
//
//  @main 入口
//

import SwiftUI
import Sparkle

@main
struct ReimbursementNativeApp: App {
    @State private var state = AppState()

    // Sparkle 更新控制器：startingUpdater=true 表示启动即按 Info.plist 的
    // SUFeedURL / SUScheduledCheckInterval 安排自动检查（后台下载、提示后重启生效）。
    // 须在 App 生命周期内常驻，故随 @main 一起创建（Sparkle 官方 SwiftUI 接入方式）。
    private let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    var body: some Scene {
        WindowGroup("报销整理") {
            ContentView()
                .environment(state)
                .frame(minWidth: 960, minHeight: 640)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于 报销整理") {
                    state.showAbout = true
                }
            }
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
            CommandGroup(replacing: .newItem) {
                Button("新建整理") {
                    state.startNewSession()
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
            CommandGroup(after: .newItem) {
                Button("补传票据") {
                    state.advance(to: .upload)
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(state.currentSession == nil)
            }
            CommandGroup(replacing: .appSettings) {
                Button("⛭ 设置…") {
                    state.showSettings = true
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
            CommandGroup(replacing: .appTermination) {
                Button("退出 报销整理") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: [.command])
            }
        }
    }
}
