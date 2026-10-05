//
//  Theme.swift
//  报销整理Native
//
//  全局主题：品牌色等（避免散落各处）。
//

import SwiftUI

extension Color {
    /// 品牌橙色（统一原散落各处的 0.98 / 0.36 / 0.10）
    static let brandOrange = Color(red: 0.98, green: 0.36, blue: 0.10)
}

extension ShapeStyle where Self == Color {
    /// 品牌橙色的 ShapeStyle 版，供 `foregroundStyle(.brandOrange)` / `.tint(.brandOrange)` 等前导点语法解析
    static var brandOrange: Color { Color.brandOrange }
}

extension View {
    /// 主行动按钮统一风格（橙色 prominent）
    /// 原生按钮自带 hover 反馈，无需额外 hoverScale。
    func primaryAction() -> some View {
        self
            .buttonStyle(.borderedProminent)
            .tint(.brandOrange)
    }
}
