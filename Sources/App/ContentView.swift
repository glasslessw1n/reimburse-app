//
//  ContentView.swift
//  报销整理Native
//

import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) var state: AppState

    var body: some View {
        @Bindable var state = state
        ZStack {
            // 背景色 + 品牌图（首页靠右，其余页面居中）
            Color(nsColor: .windowBackgroundColor)
                .overlay(alignment: state.page == .home ? .trailing : .center) {
                    brandImage
                }

            switch state.page {
            case .home:
                HomeView()
            case .workspace:
                WorkspaceView()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: state.page)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $state.showSettings) {
            SettingsView()
                .environment(state)
        }
    }

    /// 品牌背景图：首页靠右 140% 透明度 70%，其余页面居中 50%
    private var brandImage: some View {
        Group {
            if let url = Bundle.main.url(forResource: "background", withExtension: "png"),
               let nsImage = NSImage(contentsOf: url) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: state.page == .home ? 870 : 620, height: state.page == .home ? 870 : 620)
                    .opacity(state.page == .home ? 0.7 : 0.5)
                    .padding(.trailing, state.page == .home ? 20 : 0)
                    .allowsHitTesting(false)
                    .animation(.easeInOut(duration: 0.3), value: state.page)
            }
        }
    }
}

#Preview {
    ContentView()
        .environment(AppState())
}
