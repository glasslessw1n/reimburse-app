//
//  AboutView.swift
//  报销整理Native
//
//  「关于 报销整理」：应用信息 + 源码仓库链接 + 内部使用声明。
//  替代系统标准 About 面板（样式不可控、放不下声明文本）。
//

import SwiftUI
import AppKit

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "版本 \(version)（构建 \(build)）"
    }

    var body: some View {
        VStack(spacing: 18) {
            // 头部：图标 + 名称 + 版本 + 一句简介
            VStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 88, height: 88)
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)

                Text("报销整理")
                    .font(.system(size: 24, weight: .bold))

                Text(versionText)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Text("差旅报销票据的本地整理工具：识别、归类、核对与打包导出。除你自行配置的大模型服务外，数据不离开本机。")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 源码仓库
            Link(destination: URL(string: "https://github.com/glasslessw1n/reimburse-app")!) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                    Text("github.com/glasslessw1n/reimburse-app")
                    Image(systemName: "arrow.up.right")
                        .font(.caption2.weight(.semibold))
                }
                .font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .help("在浏览器打开 GitHub 仓库")

            Divider()

            // 使用声明
            VStack(alignment: .leading, spacing: 8) {
                Label("使用声明", systemImage: "lock.shield")
                    .font(.headline)
                Text("本软件仅供开发者所在单位内部相关人员在差旅报销整理场景下使用，不得向任何外部单位或个人传播、分发、出售或提供使用。使用者须妥善保管经手的票据与数据；因违规传播、超范围使用或不当操作引发的任何后果与责任，由使用人自行承担，与开发者无关。本软件按「现状」提供，识别与归类结果仅供参考，不构成对准确性的承诺，正式提交前请自行核对原始票据。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.primary.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 0.5)
            )

            HStack {
                Text("© 2026 glasslessw1n")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("关闭") { dismiss() }
                    .primaryAction()
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 460)
    }
}

#Preview {
    AboutView()
}
