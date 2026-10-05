//
//  HomeView.swift
//  报销整理Native
//
//  首页：左侧 hero（标题 + 副标题）+ 右侧操作指引（按现流程）
//  对应 web 版 hero-text + hero-howto
//

import SwiftUI

struct HomeView: View {
    @Environment(AppState.self) var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            // 顶部 status bar
            HStack {
                Spacer()
                StatusBadges()
            }
            .padding(.horizontal, 32)
            .padding(.top, 20)

            Spacer()

            // Hero 区（左右两栏）
            HStack(alignment: .top, spacing: 60) {
                // 左：标题 + 副标题 + 开始按钮
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        (
                            Text("把")
                                .font(.system(size: 56, weight: .bold))
                                .foregroundColor(.primary)
                            +
                            Text("发票")
                                .font(.system(size: 56, weight: .bold))
                                .foregroundColor(.brandOrange)
                            +
                            Text("变成")
                                .font(.system(size: 56, weight: .bold))
                                .foregroundColor(.primary)
                            +
                            Text("\n结构化数据")
                                .font(.system(size: 56, weight: .bold))
                                .foregroundColor(.brandOrange)
                        )

                        Text("上传票据，LLM 自动识别票据类型、抽取关键字段、关联水单发票、按行程归档。一键生成报销明细。")
                            .font(.system(size: 15))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: 460, alignment: .leading)
                            .padding(.top, 12)
                    }

                    // 未配置 LLM 时引导用户先配置
                    if !state.llmConfigured {
                        HStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.system(size: 16))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("尚未配置 LLM")
                                    .font(.system(size: 13, weight: .semibold))
                                Text("配置后才能自动识别票据类型和字段")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button("去配置") {
                                state.showSettings = true
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.brandOrange)
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.orange.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.orange.opacity(0.25), lineWidth: 0.5)
                        )
                        .frame(maxWidth: 460)
                    }

                    Button {
                        state.startNewSession()
                    } label: {
                        Text("开始整理 →")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.brandOrange)
                            )
                    }
                    .buttonStyle(.plain)
                    .shadow(color: Color.brandOrange.opacity(0.35), radius: 10, y: 3)
                    .padding(.top, 8)
                    .hoverScale(1.05)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // 右：操作指引
                HowToCard()
                    .frame(maxWidth: 460, alignment: .trailing)
            }
            .padding(.horizontal, 48)

            // 最近会话（有历史时显示）
            if !state.sessions.isEmpty {
                RecentSessionsSection(sessions: state.sessions) { sid in
                    state.resumeSession(sid: sid)
                }
                .padding(.horizontal, 48)
                .padding(.top, 28)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { state.refreshSessions() }
    }
}

/// 首页「最近会话」列表
private struct RecentSessionsSection: View {
    let sessions: [SessionSummary]
    let onResume: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最近会话")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            ForEach(sessions.prefix(5)) { s in
                SessionRow(summary: s) { onResume(s.sid) }
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
    }
}

private struct SessionRow: View {
    let summary: SessionSummary
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(summary.billCount) 张票据 · \(summary.tripCount) 个行程")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                    Text(summary.createdLabel)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(hovering ? Color.gray.opacity(0.10) : Color.gray.opacity(0.05))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 右侧操作指引卡片（对齐 web 版 hero-howto）
private struct HowToCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(Color.brandOrange)
                        .frame(width: 22, height: 22)
                    Text("i")
                        .font(.system(size: 13, weight: .bold, design: .serif))
                        .foregroundColor(.white)
                }
                Text("操作指引")
                    .font(.system(size: 15, weight: .semibold))
            }
            .padding(.bottom, 4)

            VStack(alignment: .leading, spacing: 10) {
                HowToRow(num: "1", text: "配 LLM — 点顶部LLM图标，选 Provider（DeepSeek / OpenAI / Ollama / 自定义 等），填 API Key，「拉取模型」选好后保存。")
                HowToRow(num: "2", text: "点「开始整理」拖文件 — 把 PDF / 图片拖到上传框，一次可多张，自动 OCR + LLM 识别，拖放区下方实时显示结果。")
                HowToRow(num: "3", text: "整理归类 — 点「下一步：整理」，按日期 + 城市连通性自动合并差旅行程。")
                HowToRow(num: "4", text: "保存到下载目录 — 点「保存到下载目录」一键落盘 ZIP，路径可直接复制或在 Finder 中打开。")
            }
        }
        .padding(20)
        .background { VisualEffectView().clipShape(RoundedRectangle(cornerRadius: 12)).allowsHitTesting(false) }
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.gray.opacity(0.15), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.14), radius: 18, y: 6)
        .hoverScale(1.02)
    }
}

private struct HowToRow: View {
    let num: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.brandOrange.opacity(0.12))
                    .frame(width: 22, height: 22)
                Text(num)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.brandOrange)
            }
            VStack(alignment: .leading, spacing: 2) {
                // 高亮粗体的"动作短语"
                if let (head, rest) = splitHeadTail(text) {
                    Text(.init("**\(head)** — \(rest)"))
                        .font(.system(size: 13))
                        .foregroundColor(.primary)
                } else {
                    Text(text)
                        .font(.system(size: 13))
                        .foregroundColor(.primary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 拆 "** 拖文件 ** — ..." 为 ("拖文件", "...")
    private func splitHeadTail(_ s: String) -> (String, String)? {
        guard let r = s.range(of: "**") else { return nil }
        let head = String(s[r.upperBound...])
        // 跳到下一个 ** 后的 —
        guard let endRange = head.range(of: "**") else { return nil }
        let bold = String(head[..<endRange.lowerBound])
        var tail = String(head[endRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        if tail.hasPrefix("—") {
            tail = String(tail.dropFirst()).trimmingCharacters(in: .whitespaces)
        } else if tail.hasPrefix("-") {
            tail = String(tail.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return (bold, tail)
    }
}

#Preview {
    HomeView()
        .environment(AppState())
}
