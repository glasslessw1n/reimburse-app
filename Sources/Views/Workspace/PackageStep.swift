//
//  PackageStep.swift
//  报销整理Native
//
//  打包 + 保存到下载目录 + 在 Finder 里显示。
//

import SwiftUI
import AppKit

@MainActor
final class PackageViewModel: ObservableObject {
    @Published var packing = false
    @Published var error: String?
    @Published var savedURL: URL?

    func package(session: SessionManager, includeExcel: Bool = false) async {
        packing = true
        error = nil
        savedURL = nil
        defer { packing = false }

        do {
            // 1. 物理文件搬到 trips/
            try ZipPackager.arrangeFiles(session: session)
            // 2. 打 ZIP
            let url = try ZipPackager.package(session: session, includeExcel: includeExcel)
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
    @EnvironmentObject var state: AppState
    @StateObject private var vm = PackageViewModel()
    @State private var includeExcel = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    if vm.savedURL != nil {
                        successView
                    } else if let err = vm.error {
                        errorView(err)
                    } else {
                        readyView
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
            }

            Divider()

            HStack {
                Button("返回整理") {
                    state.advance(to: .finalize)
                }
                .buttonStyle(.bordered)
                .disabled(vm.packing)

                Spacer()

                if vm.savedURL == nil {
                    Button {
                        Task { await vm.package(session: state.currentSession!, includeExcel: includeExcel) }
                    } label: {
                        HStack {
                            if vm.packing { ProgressView().scaleEffect(0.5) }
                            Text(vm.packing ? "打包中…" : "保存到下载目录")
                        }
                        .frame(minWidth: 140)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.98, green: 0.36, blue: 0.10))
                    .disabled(state.currentSession?.manifest.bills.isEmpty ?? true || vm.packing)
                } else {
                    Button("再来一次") {
                        state.clearCurrentSession()
                        state.page = .home
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.98, green: 0.36, blue: 0.10))
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    private var readyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "archivebox.fill")
                .font(.system(size: 48))
                .foregroundColor(.gray.opacity(0.6))
            Text("准备打包")
                .font(.system(size: 18, weight: .semibold))
            if let session = state.currentSession {
                Text("\(session.manifest.trips.count) 个行程 · \(session.manifest.local.count) 项本地 · 共 \(session.manifest.bills.count) 张")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            Toggle("生成 Excel 明细（暂未实现）", isOn: $includeExcel)
                .toggleStyle(.checkbox)
                .disabled(true)
        }
    }

    private var successView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundColor(.green)
            Text("已保存")
                .font(.system(size: 22, weight: .semibold))
            if let url = vm.savedURL {
                // 绝对路径（可选择 + 复制）
                VStack(alignment: .leading, spacing: 6) {
                    Text("保存路径")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
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
                        .help("复制路径")
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 8)

                Button {
                    vm.revealInFinder()
                } label: {
                    Label("在 Finder 中显示", systemImage: "folder")
                        .frame(minWidth: 160)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.98, green: 0.36, blue: 0.10))
                .padding(.top, 12)
            }
        }
    }

    private func errorView(_ err: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(.orange)
            Text("打包失败")
                .font(.system(size: 18, weight: .semibold))
            Text(err)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }
}

#Preview {
    PackageStep()
        .environmentObject(AppState())
}
