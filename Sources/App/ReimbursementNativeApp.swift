//
//  ReimbursementNativeApp.swift
//  报销整理Native
//
//  @main 入口
//

import SwiftUI

@main
struct ReimbursementNativeApp: App {
    @State private var state = AppState()

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
                    NSApplication.shared.orderFrontStandardAboutPanel(nil)
                }
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
                Button("设置…") {
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
