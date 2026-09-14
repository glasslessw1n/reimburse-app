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

@MainActor
final class UploadViewModel: ObservableObject {
    @Published var isTargeted = false
    @Published var processing = false
    @Published var total = 0
    @Published var done = 0
    @Published var current: String = ""
    @Published var stage: String = "准备上传…"
    @Published var lastError: String?

    /// 单张图片的处理：原文件 → OCR → LLM → BillInfo
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

        // 2. 存原文件
        do {
            _ = try session.saveOriginal(data: data, filename: filename)
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

        // 5. 转 BillInfo
        return toBillInfo(receipt: receipt, sourceFile: filename, rawText: ocrText)
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
}

struct UploadStep: View {
    @EnvironmentObject var state: AppState
    @StateObject private var vm = UploadViewModel()

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
                        .foregroundColor(.secondary)
                    Spacer()
                    if session.manifest.needsReviewCount > 0 {
                        Label("\(session.manifest.needsReviewCount) 张需确认",
                              systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 8)

                // 列表（自适应垂直滚动）
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(session.manifest.bills) { bill in
                            BillRow(bill: bill)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
                }
                .frame(maxHeight: .infinity)
            } else if !vm.processing {
                // 空状态提示
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 36))
                        .foregroundColor(.gray.opacity(0.3))
                    Text("拖入 PDF 或图片开始识别")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else {
                Spacer()
            }

            Divider()

            // 底部按钮栏
            HStack {
                Button("清空") {
                    if let session = state.currentSession {
                        session.manifest.bills.removeAll()
                        session.manifest.needsReviewCount = 0
                        session.save()
                    }
                }
                .buttonStyle(.bordered)
                .disabled(state.currentSession?.manifest.bills.isEmpty ?? true)

                Spacer()

                Button {
                    state.advance(to: .finalize)
                } label: {
                    Text("下一步：整理 →")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.98, green: 0.36, blue: 0.10))
                .disabled(state.currentSession?.manifest.bills.isEmpty ?? true || vm.processing)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
    }

    /// 进度面板：spinner + stage + 进度条 + 当前文件名
    private var progressPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(vm.stage)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                Spacer()
                Text("\(vm.done) / \(vm.total)")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundColor(.secondary)
            }
            ProgressBar(value: progress, label: "")
            if !vm.current.isEmpty {
                Text(vm.current)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.06))
        )
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
        .environmentObject(AppState())
}
