//
//  PackageStep.swift
//  报销整理Native
//
//  打包 + 保存到下载目录 + 在 Finder 里显示。
//

import SwiftUI
import AppKit

@MainActor
@Observable
final class PackageViewModel {
    var packing = false
    var error: String?
    var savedURL: URL?

    func package(session: SessionManager, includeExcel: Bool, homeCities: Set<String>) async {
        packing = true
        error = nil
        savedURL = nil
        defer { packing = false }

        do {
            // 1. 物理文件搬到 trips/
            try ZipPackager.arrangeFiles(session: session)
            // 2. 打 ZIP（includeExcel 由勾选框控制）
            let url = try ZipPackager.package(session: session, includeExcel: includeExcel, homeCities: homeCities)
            savedURL = url
        } catch {
            self.error = error.localizedDescription
        }
    }

    func revealInFinder() {
        guard let url = savedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func startOver() {
        savedURL = nil
        error = nil
    }
}

struct PackageStep: View {
    @Environment(AppState.self) var state: AppState
    @State private var vm = PackageViewModel()
    @State private var includeExcel = true

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                ScrollView {
                    statusCard
                        .frame(maxWidth: 520)
                        .frame(maxWidth: .infinity)   // 水平居中
                        .padding(.horizontal, 32)
                        .padding(.vertical, 24)
                        .frame(minHeight: geo.size.height, alignment: .center)  // 垂直居中
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                Button("返回整理") {
                    state.advance(to: .finalize)
                }
                .buttonStyle(.bordered)
                .hoverLift()
                .disabled(vm.packing)

                Spacer()

                if vm.savedURL == nil {
                    Button {
                        Task { await vm.package(session: state.currentSession!, includeExcel: includeExcel, homeCities: state.settingsStore.settings.homeCities) }
                    } label: {
                        HStack {
                            if vm.packing { ProgressView().scaleEffect(0.5) }
                            Text(vm.packing ? "打包中…" : "保存到下载目录")
                        }
                        .frame(minWidth: 140)
                    }
                    .primaryAction()
                    .disabled(state.currentSession?.manifest.bills.isEmpty ?? true || vm.packing)
                } else {
                    Button("再来一次") {
                        state.clearCurrentSession()
                        state.page = .home
                    }
                    .primaryAction()
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    /// 中间状态卡片（圆角玻璃卡包裹，居中显示，与背景区分）
    @ViewBuilder
    private var statusCard: some View {
        Group {
            if vm.savedURL != nil {
                successView
            } else if let err = vm.error {
                errorView(err)
            } else {
                readyView
            }
        }
        .padding(24)
        .background { VisualEffectView().clipShape(RoundedRectangle(cornerRadius: 12)).allowsHitTesting(false) }
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.gray.opacity(0.15), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.14), radius: 18, y: 6)
    }

    private var readyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "archivebox.fill")
                .font(.system(size: 48))
                .foregroundStyle(.gray.opacity(0.6))
            Text("准备打包")
                .font(.system(size: 18, weight: .semibold))
            if let session = state.currentSession {
                Text("\(session.manifest.trips.count) 个行程 · \(session.manifest.local.count) 项本地 · 共 \(session.manifest.bills.count) 张")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Toggle("生成 报销明细.xlsx", isOn: $includeExcel)
                .toggleStyle(.checkbox)
        }
    }

    private var successView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("已保存")
                .font(.system(size: 22, weight: .semibold))
            if let url = vm.savedURL {
                // 绝对路径（可选择 + 复制）
                VStack(alignment: .leading, spacing: 6) {
                    Text("保存路径")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text(url.path)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.gray.opacity(0.08))
                            )
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.path, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 13))
                        }
                        .buttonStyle(.bordered)
                        .hoverLift()
                        .help("复制路径")
                    }
                }
                .padding(.top, 8)

                Button {
                    vm.revealInFinder()
                } label: {
                    Label("在 Finder 中显示", systemImage: "folder")
                        .frame(minWidth: 160)
                }
                .primaryAction()
                .padding(.top, 12)
            }
        }
    }

    private func errorView(_ err: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("打包失败")
                .font(.system(size: 18, weight: .semibold))
            Text(err)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
    }
}

#Preview {
    PackageStep()
        .environment(AppState())
}
