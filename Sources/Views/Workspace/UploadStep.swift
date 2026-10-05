//
//  UploadStep.swift
//  报销整理Native
//
//  上传 + 识别一步完成（对应 web 版 Step 1 + Step 2）
//  - 顶部拖放区（常驻）
//  - 拖放区下方实时显示识别结果列表
//  - 列表超长时自适应垂直滚动条
//  - 处理中显示进度面板（stage 文字 + 进度条 + 当前文件名）
//  - 完成后按钮显示「下一步：整理」
//

import SwiftUI

/// 票据列表排序/筛选
enum BillSortMode: String, CaseIterable, Hashable {
    case original = "默认顺序"
    case byType = "按类型"
    case byDate = "按日期"
    case reviewOnly = "只看需确认"
}

@MainActor
@Observable
final class UploadViewModel {
    var isTargeted = false
    var processing = false
    var total = 0
    var done = 0
    var current: String = ""
    var stage: String = "准备上传…"
    var lastError: String?

    /// 单张图片的处理流程：
    ///   上传 → 存原文件 → OCR → LLM 识别 receiptType → 打包 boarding_pass → BillInfo
    ///   boarding_pass 在识别为 boarding_pass 后裁切 PDF 并替换 originals/ 里的版本（用于打包）
    func processFile(_ url: URL, session: SessionManager, recognizer: LLMRecognizer) async -> BillInfo {
        let filename = url.lastPathComponent
        current = filename

        // 1. 读 bytes
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return BillInfo(
                billType: .other, sourceFile: filename,
                error: "读文件失败：\(error.localizedDescription)"
            )
        }

        // 2. 存原文件（同名自动改名，避免覆盖；sourceFile 用实际落盘名）
        let sourceFilename: String
        do {
            sourceFilename = try session.saveOriginal(data: data, filename: filename).lastPathComponent
        } catch {
            return BillInfo(
                billType: .other, sourceFile: filename,
                error: "保存失败：\(error.localizedDescription)"
            )
        }

        // 3. OCR
        let suffix = url.pathExtension
        let ocrText: String
        do {
            stage = "OCR 识别 \(filename)"
            ocrText = try await TextExtractor.extract(data: data, suffix: suffix)
        } catch {
            return BillInfo(
                billType: .other, sourceFile: filename,
                error: "OCR 失败：\(error.localizedDescription)"
            )
        }

        // 4. LLM
        stage = "LLM 抽取字段 \(filename)"
        let receipt = await recognizer.recognize(
            ocrText: ocrText, filename: filename, sourceFile: filename
        )

        // 5. boarding_pass → 裁切原 PDF，替换 originals/ 里的版本（用于打包）
        if receipt.receiptType == .boardingPass,
           suffix.lowercased() == "pdf",
           let cropped = PDFRenderer.cropBoardingPass(pdfData: data) {
            do {
                stage = "裁切登机牌 \(filename)"
                _ = try session.saveOriginal(data: cropped, filename: sourceFilename, overwrite: true)
            } catch {
                // 裁切替换失败不影响识别结果
                print("[upload] 裁切替换失败: \(error)")
            }
        }

        // 6. 转 BillInfo
        return toBillInfo(receipt: receipt, sourceFile: sourceFilename, rawText: ocrText)
    }

    private func toBillInfo(receipt: Receipt, sourceFile: String, rawText: String) -> BillInfo {
        let amount: Double = {
            if let amtStr = receipt.field("amount"), let d = Double(amtStr) { return d }
            return 0
        }()
        let reviewReason = receipt.needsReview
            ? (receipt.error.isEmpty ? "必填字段缺失或置信度过低" : receipt.error)
            : ""
        return BillInfo(
            billType: receipt.receiptType,
            amount: amount,
            sourceFile: sourceFile,
            fields: receipt.fields,
            needsReview: receipt.needsReview,
            reviewReason: reviewReason,
            confidence: receipt.confidence,
            rawTextSnippet: String(rawText.prefix(300)),
            error: receipt.error
        )
    }

    /// 重新识别单张：读原文件重跑 OCR+LLM，替换同 uid 的旧票据（保留 uid 保持列表身份稳定）
    func reRecognize(_ bill: BillInfo, session: SessionManager, recognizer: LLMRecognizer) async {
        let src = session.rootDir.appendingPathComponent("originals").appendingPathComponent(bill.sourceFile)
        guard let data = try? Data(contentsOf: src) else { return }

        let suffix = (bill.sourceFile as NSString).pathExtension
        stage = "重新识别 \(bill.sourceFile)"
        let ocrText = (try? await TextExtractor.extract(data: data, suffix: suffix)) ?? ""
        let receipt = await recognizer.recognize(
            ocrText: ocrText, filename: bill.sourceFile, sourceFile: bill.sourceFile
        )

        var newBill = toBillInfo(receipt: receipt, sourceFile: bill.sourceFile, rawText: ocrText)
        newBill.uid = bill.uid   // 保留身份，避免列表行跳位
        session.replaceBill(newBill)
    }
}

struct UploadStep: View {
    @Environment(AppState.self) var state: AppState
    @State private var vm = UploadViewModel()
    @State private var showClearConfirm = false
    @State private var sortMode: BillSortMode = .original

    /// 根据排序/筛选模式返回要显示的票据
    private var displayedBills: [BillInfo] {
        guard let session = state.currentSession else { return [] }
        var bills = session.manifest.bills
        switch sortMode {
        case .original:
            break
        case .byType:
            bills.sort { $0.billType.rawValue < $1.billType.rawValue }
        case .byDate:
            bills.sort { ($0.dateMMDDs.first ?? "") < ($1.dateMMDDs.first ?? "") }
        case .reviewOnly:
            bills = bills.filter { $0.needsReview }
        }
        return bills
    }

    var body: some View {
        VStack(spacing: 0) {
            // 拖放区（常驻）
            DropZone(isTargeted: $vm.isTargeted, onFiles: { urls in
                Task { await processAll(urls) }
            })
            .padding(.horizontal, 24)
            .padding(.top, 16)

            // 进度面板（仅处理中显示）
            if vm.processing {
                progressPanel
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
            }

            // 识别结果列表（已有结果时显示）
            if let session = state.currentSession, !session.manifest.bills.isEmpty {
                Divider()
                    .padding(.top, 16)

                // 标题 + 计数
                HStack {
                    Text("识别结果")
                        .font(.system(size: 13, weight: .semibold))
                    Text("(\(session.manifest.bills.count))")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if session.manifest.needsReviewCount > 0 {
                        ReviewBadge(count: session.manifest.needsReviewCount)
                    }
                    Picker("", selection: $sortMode) {
                        ForEach(BillSortMode.allCases, id: \.self) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 8)

                // 列表（自适应垂直滚动）
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(displayedBills) { bill in
                            BillRow(bill: bill)
                                .contextMenu {
                                    Button("重新识别") {
                                        Task { await reRecognize(bill) }
                                    }
                                    .disabled(vm.processing)
                                    Divider()
                                    Button("删除", role: .destructive) {
                                        state.currentSession?.removeBill(uid: bill.uid)
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
                }
                .frame(maxHeight: .infinity)
            } else if !vm.processing {
                ContentUnavailableView {
                    Label("拖入 PDF 或图片", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text("支持 PDF / JPG / PNG，一次可拖多张")
                }
            } else {
                Spacer()
            }

            Divider()

            // 底部按钮栏
            HStack {
                Button("清空") {
                    showClearConfirm = true
                }
                .buttonStyle(.bordered)
                .hoverScale()
                .disabled(state.currentSession?.manifest.bills.isEmpty ?? true)

                Spacer()

                Button {
                    // 触发 SessionManager.finalize() 跑行程归类（按日期+城市连通性合并）
                    state.currentSession?.finalize()
                    state.advance(to: .finalize)
                } label: {
                    Text("下一步：整理 →")
                }
                .buttonStyle(.borderedProminent)
                .tint(.brandOrange)
                .hoverScale()
                .disabled(state.currentSession?.manifest.bills.isEmpty ?? true || vm.processing)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .alert("确认清空？", isPresented: $showClearConfirm) {
            Button("取消", role: .cancel) { }
            Button("清空", role: .destructive) { clearAll() }
        } message: {
            Text("将删除当前会话的所有识别结果与原文件，该操作不可撤销。")
        }
    }

    /// 清空：删除 bills / trips / local / originals 目录
    private func clearAll() {
        guard let session = state.currentSession else { return }
        session.manifest.bills.removeAll()
        session.manifest.trips.removeAll()
        session.manifest.local.removeAll()
        session.manifest.needsReviewCount = 0
        // 删原文件目录（避免下次同 session 复用）
        let originals = session.rootDir.appendingPathComponent("originals")
        try? FileManager.default.removeItem(at: originals)
        try? FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        session.save()
        // 强制刷新（SwiftUI 对 array 的同 identity mutation 不一定刷）
        state.currentSession = session
    }

    /// 重新识别单张票据（右键菜单触发）
    private func reRecognize(_ bill: BillInfo) async {
        guard let session = state.currentSession else { return }
        let recognizer = LLMRecognizer(
            client: LLMClient(config: state.settingsStore.settings.llmConfig)
        )
        await vm.reRecognize(bill, session: session, recognizer: recognizer)
    }

    /// 进度面板：spinner + stage + 进度条 + 当前文件名
    private var progressPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(vm.stage)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(vm.done) / \(vm.total)")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressBar(value: progress, label: "")
            if !vm.current.isEmpty {
                Text(vm.current)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(12)
        .background { VisualEffectView().clipShape(RoundedRectangle(cornerRadius: 8)).allowsHitTesting(false) }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.15), lineWidth: 0.5)
        )
    }

    private var progress: Double {
        vm.total == 0 ? 0 : Double(vm.done) / Double(vm.total)
    }

    private func processAll(_ urls: [URL]) async {
        guard let session = state.currentSession else { return }
        let recognizer = LLMRecognizer(
            client: LLMClient(config: state.settingsStore.settings.llmConfig)
        )

        vm.processing = true
        vm.total = urls.count
        vm.done = 0
        vm.lastError = nil
        vm.stage = "准备上传…"
        defer { vm.processing = false }

        await withTaskGroup(of: BillInfo.self) { group in
            var pending = 0
            let max = 4

            for url in urls {
                if pending >= max {
                    if let bill = await group.next() {
                        await MainActor.run {
                            session.ingest(bill)
                            vm.done += 1
                        }
                        pending -= 1
                    }
                }
                group.addTask {
                    await vm.processFile(url, session: session, recognizer: recognizer)
                }
                pending += 1
            }

            for await bill in group {
                await MainActor.run {
                    session.ingest(bill)
                    vm.done += 1
                }
            }
        }
        vm.stage = "识别完成"
        vm.current = ""
    }
}

#Preview {
    UploadStep()
        .environment(AppState())
}
