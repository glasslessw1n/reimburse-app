//
//  VisualEffectView.swift
//  报销整理Native
//
//  macOS 毛玻璃（类似 Dock 背景）：用 NSVisualEffectView 的「窗口内混合」模式，
//  模糊的是窗口内部的内容（如背景图），而非 SwiftUI .material 的窗口后方桌面。
//
//  - PassthroughVisualEffectView 让鼠标点击穿透，避免拦截 SwiftUI 的 onTapGesture。
//  - alpha 控制磨砂透明度（越小越透）。
//

import SwiftUI
import AppKit

/// 不拦截鼠标事件的 NSVisualEffectView（让点击穿透到背后的 SwiftUI 内容）
final class PassthroughVisualEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blendingMode: NSVisualEffectView.BlendingMode = .withinWindow
    /// 磨砂不透明度（默认 0.85 = 更透 15%）
    var alpha: CGFloat = 0.85
    /// 磨砂强度：.active（正常）/ .inactive（更轻、更透）
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> PassthroughVisualEffectView {
        let view = PassthroughVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.alphaValue = alpha
        return view
    }

    func updateNSView(_ nsView: PassthroughVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
        nsView.alphaValue = alpha
    }
}
