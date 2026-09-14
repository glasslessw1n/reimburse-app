//
//  ContentView.swift
//  报销整理Native
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
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
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
