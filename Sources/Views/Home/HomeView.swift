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
            Spacer()

            // Hero 区（左右两栏）
            HStack(alignment: .top, spacing: 60) {
                // 左：标题 + 副标题 + 开始按钮
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        (
                            Text("把")
                                .font(.system(size: 56, weight: .bold))
                                .foregroundStyle(.primary)
                            +
                            Text("发票")
                                .font(.system(size: 56, weight: .bold))
                                .foregroundStyle(.brandOrange)
                            +
                            Text("变成")
                                .font(.system(size: 56, weight: .bold))
                                .foregroundStyle(.primary)
                            +
                            Text("\n结构化数据")
                                .font(.system(size: 56, weight: .bold))
                                .foregroundStyle(.brandOrange)
                        )

                        Text("上传票据，LLM 自动识别票据类型、抽取关键字段、关联水单发票、按行程归档。一键生成报销明细。")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 460, alignment: .leading)
                            .padding(.top, 12)
                    }

                    // 未配置 LLM 时引导用户先配置
                    if !state.llmConfigured {
                        HStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.system(size: 16))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("尚未配置 LLM")
                                    .font(.system(size: 13, weight: .semibold))
                                Text("配置后才能自动识别票据类型和字段")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("去配置") {
                                state.showSettings = true
                            }
                            .primaryAction()
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
                            .font(.system(size: 15, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                    }
                    .primaryAction()
                    .keyboardShortcut(.defaultAction)
                    .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // 右：操作指引 + 最近会话（信息栏，两个卡片同风格）
                VStack(alignment: .leading, spacing: 16) {
                    HowToCard()
                    if !state.sessions.isEmpty {
                        RecentSessionsSection(
                            sessions: state.sessions,
                            onResume: { sid in state.resumeSession(sid: sid) },
                            onClear: { state.clearHistory() }
                        )
                    }
                }
                .frame(width: 460, alignment: .leading)
            }
            .padding(.horizontal, 48)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { state.refreshSessions() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                StatusBadges()
            }
        }
    }
}

/// 首页「最近会话」卡片（右侧信息栏，与操作指引同风格）
private struct RecentSessionsSection: View {
    let sessions: [SessionSummary]
    let onResume: (String) -> Void
    let onClear: () -> Void
    @State private var showClearConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("最近会话")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("清空历史") {
                    showClearConfirm = true
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .help("删除所有历史会话")
            }
            .padding(.bottom, 6)

            ForEach(sessions.prefix(4)) { s in
                SessionRow(summary: s) { onResume(s.sid) }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { VisualEffectView().clipShape(RoundedRectangle(cornerRadius: 12)).allowsHitTesting(false) }
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.gray.opacity(0.15), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.14), radius: 18, y: 6)
        .alert("清空历史？", isPresented: $showClearConfirm) {
            Button("取消", role: .cancel) { }
            Button("清空", role: .destructive) { onClear() }
        } message: {
            Text("将删除所有历史会话，该操作不可撤销。")
        }
    }
}

private struct SessionRow: View {
    let summary: SessionSummary
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("\(summary.billCount) 张 · \(summary.tripCount) 行程")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer()
                Text(summary.createdLabel)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(hovering ? Color.gray.opacity(0.10) : Color.gray.opacity(0.045))
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
                        .foregroundStyle(.white)
                }
                Text("操作指引")
                    .font(.system(size: 15, weight: .semibold))
            }
            .padding(.bottom, 4)

            VStack(alignment: .leading, spacing: 10) {
                HowToRow(num: "1", head: "配置", tail: "点右上角齿轮图标，选 Provider（DeepSeek / OpenAI / Ollama 等），填 API Key，测试连接后保存。")
                HowToRow(num: "2", head: "开始整理", tail: "点「开始整理」新建会话，或从下方「最近会话」继续上次未完成的。")
                HowToRow(num: "3", head: "上传识别", tail: "把 PDF / 图片拖入上传框，自动 OCR + LLM 识别；识别有误可右键单票「重新识别」或「删除」。")
                HowToRow(num: "4", head: "整理打包", tail: "点「下一步：整理」自动合并行程，检查后「保存到下载目录」生成 ZIP + 报销明细。")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { VisualEffectView().clipShape(RoundedRectangle(cornerRadius: 12)).allowsHitTesting(false) }
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.gray.opacity(0.15), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.14), radius: 18, y: 6)
    }
}

private struct HowToRow: View {
    let num: String
    let head: String
    let tail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.brandOrange.opacity(0.12))
                    .frame(width: 22, height: 22)
                Text(num)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.brandOrange)
            }
            VStack(alignment: .leading, spacing: 2) {
                // 动作短语加粗 + 说明
                Text(.init("**\(head)** — \(tail)"))
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    HomeView()
        .environment(AppState())
}
