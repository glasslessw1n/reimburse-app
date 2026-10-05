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

/// hover 浮动动效：轻微放大 + 上浮 + 阴影（尊重「减弱动态效果」）
/// - shadowColor 默认中性灰（用于灰色次要按钮），主按钮显式传品牌橙
struct HoverLift: ViewModifier {
    var scale: CGFloat = 1.03
    var shadowColor: Color = .gray
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(!reduceMotion && hovering ? scale : 1.0)
            .offset(y: !reduceMotion && hovering ? -1.5 : 0)
            .shadow(color: shadowColor.opacity(!reduceMotion && hovering ? 0.14 : 0), radius: 18, y: 6)
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovering)
    }
}

extension View {
    /// hover 浮动动效（默认 1.03，阴影默认中性灰）
    func hoverLift(_ scale: CGFloat = 1.03, shadowColor: Color = .gray) -> some View {
        modifier(HoverLift(scale: scale, shadowColor: shadowColor))
    }

    /// 主行动按钮统一风格（橙色 prominent + hover 浮动，阴影品牌橙）
    func primaryAction() -> some View {
        self
            .buttonStyle(.borderedProminent)
            .tint(.brandOrange)
            .hoverLift(shadowColor: .brandOrange)
    }
}
