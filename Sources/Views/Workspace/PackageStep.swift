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

    // MARK: - 单项导出（整合 PDF / 合并 PDF / 仅 Excel / 提交前检查）

    enum ExportKind { case composed, merged, excel }

    var exporting = false
    var exportNote: String?
    var exportError: String?
    var exportURL: URL?
    var preflightReport: PreflightReport?

    /// 导出用分组：已整理用 manifest 的 trips/local（与 ZIP 同源），未整理时现场分组
    private func groups(session: SessionManager, homeCities: Set<String>) -> (trips: [TripGroup], local: [BillInfo]) {
        if session.manifest.finalized {
            return (session.manifest.trips, session.manifest.local)
        }
        return TripResolver.assignTrips(bills: session.manifest.bills, homeCities: homeCities)
    }

    func export(kind: ExportKind, session: SessionManager, homeCities: Set<String>) async {
        exporting = true
        exportNote = nil
        exportError = nil
        exportURL = nil
        defer { exporting = false }

        let stamp = Self.timestamp()
        do {
            let (trips, local) = groups(session: session, homeCities: homeCities)
            let originals = session.rootDir.appendingPathComponent("originals")
            let url: URL
            switch kind {
            case .composed:
                let data = try PdfComposer.compose(trips: trips, local: local, originalsDir: originals)
                url = try Self.writeToDownloads(data: data, filename: "报销整合\(stamp).pdf")
                exportNote = "整合 PDF 已保存（打印版式）"
            case .merged:
                let data = try PdfMerger.merge(trips: trips, local: local, originalsDir: originals)
                url = try Self.writeToDownloads(data: data, filename: "报销合并\(stamp).pdf")
                exportNote = "合并 PDF 已保存（原样拼接）"
            case .excel:
                url = Self.downloadsURL("报销明细\(stamp).xlsx")
                if session.manifest.finalized {
                    try ExcelBuilder.build(trips: trips, local: local, outputURL: url)
                } else {
                    try ExcelBuilder.build(bills: session.manifest.bills, homeCities: homeCities, outputURL: url)
                }
                exportNote = "报销明细已保存"
            }
            exportURL = url
        } catch {
            exportError = error.localizedDescription
        }
    }

    func runPreflight(session: SessionManager) {
        preflightReport = Preflight.check(session: session)
    }

    func revealExportInFinder() {
        guard let url = exportURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private static func downloadsURL(_ filename: String) -> URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            .appendingPathComponent(filename)
    }

    private static func writeToDownloads(data: Data, filename: String) throws -> URL {
        let url = downloadsURL(filename)
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: Date())
    }
}

struct PackageStep: View {
    @Environment(AppState.self) var state: AppState
    @State private var vm = PackageViewModel()
    @State private var includeExcel = true
    @State private var showPreflight = false

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
                        HStack(spacing: 4) {
                            if vm.packing { ProgressView().scaleEffect(0.5) }
                            Text(vm.packing ? "打包中…" : "保存到下载目录")
                        }
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
            .padding(.vertical, 12)
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
        .glassCard(cornerRadius: 12)
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
                .font(.title2.weight(.semibold))
            if let session = state.currentSession {
                Text("\(session.manifest.trips.count) 个行程 · \(session.manifest.local.count) 项本地 · 共 \(session.manifest.bills.count) 张")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            Toggle("生成 报销明细.xlsx", isOn: $includeExcel)
                .toggleStyle(.checkbox)

            Divider()
                .padding(.vertical, 2)

            // 单项导出（不必走完整打包）
            VStack(spacing: 10) {
                Text("其他导出")
                    .font(.headline)
                if let session = state.currentSession {
                    HStack(spacing: 10) {
                        Button("整合 PDF") {
                            Task { await vm.export(kind: .composed, session: session, homeCities: state.settingsStore.settings.homeCities) }
                        }
                        Button("合并 PDF") {
                            Task { await vm.export(kind: .merged, session: session, homeCities: state.settingsStore.settings.homeCities) }
                        }
                        Button("仅 Excel") {
                            Task { await vm.export(kind: .excel, session: session, homeCities: state.settingsStore.settings.homeCities) }
                        }
                        Button("提交前检查") {
                            vm.runPreflight(session: session)
                            showPreflight = true
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(session.manifest.bills.isEmpty || vm.packing || vm.exporting)
                }
                if vm.exporting {
                    ProgressView()
                        .scaleEffect(0.6)
                }
                if let note = vm.exportNote {
                    HStack(spacing: 8) {
                        Text(note)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("在 Finder 中显示") { vm.revealExportInFinder() }
                            .buttonStyle(.link)
                    }
                }
                if let err = vm.exportError {
                    Text(err)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .sheet(isPresented: $showPreflight) {
            if let report = vm.preflightReport {
                PreflightView(report: report)
            }
        }
    }

    private var successView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("已保存")
                .font(.title.weight(.semibold))
            if let url = vm.savedURL {
                // 绝对路径（可选择 + 复制）
                VStack(alignment: .leading, spacing: 6) {
                    Text("保存路径")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text(url.path)
                            .font(.callout.monospaced())
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
                                .font(.body)
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
                .font(.title2.weight(.semibold))
            Text(err)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
    }
}

/// 提交前检查结果（sheet）：问题清单 + 与 Excel 同口径的分类合计
private struct PreflightView: View {
    let report: PreflightReport
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("提交前检查")
                    .font(.title3.weight(.semibold))
                Spacer()
                if report.errorCount > 0 {
                    Label("\(report.errorCount) 个错误", systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                }
                if report.warningCount > 0 {
                    Label("\(report.warningCount) 个提醒", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if report.errorCount == 0 && report.warningCount == 0 {
                    Label("全部通过", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            .padding(16)

            Divider()

            List {
                Section("检查项") {
                    ForEach(report.items) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: icon(for: item.severity))
                                .foregroundStyle(color(for: item.severity))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.body.weight(.medium))
                                Text(item.detail)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                Section("金额合计（与报销明细同口径）") {
                    ForEach(report.categoryTotals, id: \.name) { row in
                        if row.amount > 0 {
                            HStack {
                                Text(row.name)
                                Spacer()
                                Text("¥\(String(format: "%.2f", row.amount))")
                                    .monospacedDigit()
                            }
                        }
                    }
                    HStack {
                        Text("报销总计")
                            .fontWeight(.semibold)
                        Spacer()
                        Text("¥\(String(format: "%.2f", report.grandTotal))")
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }
                }
            }
            .listStyle(.inset)

            Divider()

            HStack {
                Spacer()
                Button("关闭") { dismiss() }
                    .primaryAction()
            }
            .padding(12)
        }
        .frame(width: 560, height: 600)
    }

    private func icon(for severity: PreflightItem.Severity) -> String {
        switch severity {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    private func color(for severity: PreflightItem.Severity) -> Color {
        switch severity {
        case .error: return .red
        case .warning: return .orange
        case .info: return .blue
        }
    }
}

#Preview {
    PackageStep()
        .environment(AppState())
}
