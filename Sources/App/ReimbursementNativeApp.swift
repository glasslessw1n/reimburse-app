//
//  ReimbursementNativeApp.swift
//  报销整理Native
//
//  @main 入口
//

import SwiftUI

@main
struct ReimbursementNativeApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("报销整理") {
            ContentView()
                .environmentObject(state)
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
            CommandGroup(replacing: .appTermination) {
                Button("退出 报销整理") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: [.command])
            }
        }
    }
}
