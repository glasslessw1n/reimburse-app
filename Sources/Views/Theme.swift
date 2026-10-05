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

/// 悬浮缩放动效：鼠标悬停时轻微放大（用于按钮 / 卡片）
/// 尊重「减弱动态效果」：开启时不缩放、不动画。
struct HoverScale: ViewModifier {
    var scale: CGFloat
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(!reduceMotion && hovering ? scale : 1.0)
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7), value: hovering)
    }
}

extension View {
    /// 悬浮缩放动效（默认 1.03）
    func hoverScale(_ scale: CGFloat = 1.03) -> some View {
        modifier(HoverScale(scale: scale))
    }
}
