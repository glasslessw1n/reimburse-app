//
//  AnimatedNumber.swift
//  报销整理Native
//
//  金额数字滚动动画（借鉴 RareUI「Animated counter」，用 SwiftUI 原生实现）。
//  出现时从 0 平滑滚到目标值；目标值变化时也做过渡。
//

import SwiftUI

struct AnimatedNumber: View {
    let value: Double
    var format: String = "%.2f"

    @State private var displayed: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(String(format: format, displayed))
            .monospacedDigit()
            .onAppear {
                // 尊重「减弱动态效果」：直接跳到目标值，不做滚动动画
                if reduceMotion {
                    displayed = value
                } else {
                    displayed = 0
                    withAnimation(.spring(duration: 0.8, bounce: 0.15)) {
                        displayed = value
                    }
                }
            }
            .onChange(of: value) { _, newValue in
                if reduceMotion {
                    displayed = newValue
                } else {
                    withAnimation(.spring(duration: 0.4)) {
                        displayed = newValue
                    }
                }
            }
    }
}

#Preview {
    AnimatedNumber(value: 1234.56)
        .font(.system(size: 32, weight: .semibold))
}
