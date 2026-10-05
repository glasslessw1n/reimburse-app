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
            // 背景色：与 web 版一致（graphite/paper 系）
            Color(nsColor: .windowBackgroundColor)

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
}

#Preview {
    ContentView()
        .environment(AppState())
}
