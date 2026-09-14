//
//  ProgressBar.swift
//  报销整理Native
//
//  通用进度条组件。
//

import SwiftUI

struct ProgressBar: View {
    let value: Double        // 0.0 - 1.0
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(Int(value * 100))%")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundColor(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.gray.opacity(0.15))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(red: 0.98, green: 0.36, blue: 0.10))
                        .frame(width: max(2, geo.size.width * value))
                        .animation(.easeInOut(duration: 0.15), value: value)
                }
            }
            .frame(height: 6)
        }
    }
}

#Preview {
    ProgressBar(value: 0.6, label: "识别中")
        .padding()
        .frame(width: 320)
}
