//
//  CheckForUpdatesView.swift
//  报销整理Native
//
//  Sparkle 自动更新的菜单入口：把 SPUUpdater 的 canCheckForUpdates
//  桥接成按钮可用状态。更新的检查、下载、安装与重启替换全部由
//  Sparkle 完成，这里只负责触发手动检查。
//

import SwiftUI
import Sparkle

@MainActor
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }
}

struct CheckForUpdatesView: View {
    @StateObject private var viewModel: CheckForUpdatesViewModel

    init(updater: SPUUpdater) {
        _viewModel = StateObject(wrappedValue: CheckForUpdatesViewModel(updater: updater))
    }

    var body: some View {
        Button("检查更新…") {
            viewModel.checkForUpdates()
        }
        .disabled(!viewModel.canCheckForUpdates)
    }
}
