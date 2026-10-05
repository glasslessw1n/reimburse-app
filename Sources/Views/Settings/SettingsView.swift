//
//  SettingsView.swift
//  报销整理Native
//
//  LLM 配置面板（紧凑单屏布局，无滚动条）：
//  - Provider 下拉（DeepSeek / OpenAI / 月之暗面 / 智谱 / Ollama / vLLM / 自定义）
//  - 选 Provider 自动填 Base URL + 默认 model
//  - Base URL / API Key / Model 手填
//  - 测试连接 + 拉取模型列表
//

import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) var state: AppState

    @State private var provider: LLMProvider = .deepseek
    @State private var apiKey: String = ""
    @State private var apiKeyVisible: Bool = false   // API Key 显示/隐藏
    @State private var baseURL: String = ""
    @State private var model: String = ""
    @State private var buyerName: String = ""
    @State private var buyerTaxNo: String = ""
    @State private var excludeCitiesText: String = ""
    @State private var testResult: String = ""
    @State private var testColor: Color = .secondary
    @State private var isTesting = false
    @State private var availableModels: [String] = []
    @State private var isFetchingModels = false
    @State private var showSavedTip = false
    @State private var manualBaseURL: Bool = false  // 用户改过 baseURL → 不再自动覆盖

    /// 标签宽度（行式布局：标签在左、输入框在右）
    private let labelWidth: CGFloat = 84
    /// 输入框宽度（所有字段统一此宽度，保证右边缘对齐）
    private let fieldWidth: CGFloat = 320

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text("设置")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("关闭") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            // 连接配置
            VStack(spacing: 12) {
                fieldRow("Provider") {
                    PopUpButtonWithLabel(
                        entries: LLMProvider.allCases.map { ($0, $0.rawValue) },
                        selection: $provider,
                        width: fieldWidth
                    )
                    .frame(width: fieldWidth, height: 24, alignment: .leading)
                    .onChange(of: provider) { _, new in
                        handleProviderChange(new)
                    }
                }

                let baseURLIsLocked = (provider != .custom)
                fieldRow("Base URL") {
                    TextField(baseURLIsLocked ? provider.defaultBaseURL : "https://your-provider.com/v1",
                              text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                        .disabled(baseURLIsLocked)
                        .onChange(of: baseURL) { _, _ in
                            manualBaseURL = true
                        }
                }

                fieldRow("API Key") {
                    HStack(spacing: 6) {
                        Group {
                            if apiKeyVisible {
                                TextField("sk-...", text: $apiKey)
                            } else {
                                SecureField("sk-...", text: $apiKey)
                            }
                        }
                        .textFieldStyle(.roundedBorder)

                        Button {
                            apiKeyVisible.toggle()
                        } label: {
                            Image(systemName: apiKeyVisible ? "eye.slash" : "eye")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(width: 22, height: 22)
                                .background(
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(Color.gray.opacity(0.08))
                                )
                        }
                        .buttonStyle(.plain)
                        .help(apiKeyVisible ? "隐藏 API Key" : "显示 API Key")
                    }
                }

                fieldRow("Model") {
                    HStack(spacing: 8) {
                        if availableModels.isEmpty {
                            TextField(provider.defaultModel, text: $model)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            let entries = ([(model, model)] +
                                availableModels.map { ($0, $0) })
                                .filter { !$0.0.isEmpty }
                            PopUpButtonWithLabel(
                                entries: entries,
                                selection: $model,
                                width: 220
                            )
                            .frame(width: 220, height: 24, alignment: .leading)
                        }
                        Button {
                            Task { await fetchModels() }
                        } label: {
                            HStack(spacing: 4) {
                                if isFetchingModels { ProgressView().scaleEffect(0.5) }
                                Text(isFetchingModels ? "加载中" : "拉取列表")
                                    .font(.subheadline)
                            }
                        }
                        .buttonStyle(.bordered)
                        .hoverLift()
                        .disabled(apiKey.isEmpty || baseURL.isEmpty || isFetchingModels)
                    }
                }

                if !availableModels.isEmpty {
                    Text("已发现 \(availableModels.count) 个模型")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.leading, labelWidth + 12)
                } else if !testResult.isEmpty && testColor == .red {
                    Text("提示：如果「拉取列表」报错，可手动在 Model 框输入模型名")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.leading, labelWidth + 12)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            // 购方主数据 + 常驻地
            VStack(spacing: 12) {
                HStack(spacing: 16) {
                    compactField("购方名称") {
                        TextField("XX 有限公司", text: $buyerName)
                            .textFieldStyle(.roundedBorder)
                    }
                    compactField("购方税号") {
                        TextField("9111...", text: $buyerTaxNo)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                fieldRow("常驻地") {
                    TextField("北京, 上海", text: $excludeCitiesText)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            // 反馈 + 底部按钮
            VStack(spacing: 10) {
                if !testResult.isEmpty {
                    Text(testResult)
                        .font(.subheadline)
                        .foregroundStyle(testColor)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack(spacing: 4) {
                            if isTesting { ProgressView().scaleEffect(0.5) }
                            Text(isTesting ? "测试中…" : "测试连接")
                        }
                        .frame(minWidth: 90)
                    }
                    .buttonStyle(.bordered)
                    .hoverLift()
                    .disabled(apiKey.isEmpty || baseURL.isEmpty || isTesting)

                    Spacer()

                    Button {
                        save()
                    } label: {
                        Text(showSavedTip ? "✓ 已保存" : "保存")
                            .frame(minWidth: 76)
                    }
                    .primaryAction()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 560)
        .modifier(SettingsSheetBackground())
        .onAppear { loadFromStore() }
    }

    // MARK: - 行式布局辅助

    /// 标签在左、输入框在右（主配置区用）：字段统一宽度、左对齐，保证整齐
    private func fieldRow(_ label: String, @ViewBuilder field: () -> some View) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)
            field()
                .frame(width: fieldWidth, alignment: .leading)
        }
    }

    /// 紧凑字段（购方名称/税号并排用，标签在上）：两列强制平分宽度
    private func compactField(_ label: String, @ViewBuilder field: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            field()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @Environment(\.dismiss) private var dismiss

    // MARK: - 数据

    private func loadFromStore() {
        let s = state.settingsStore.settings
        apiKey = s.apiKey
        baseURL = s.baseURL.absoluteString
        provider = LLMProvider.match(baseURL: s.baseURL.absoluteString)
        manualBaseURL = !s.baseURL.absoluteString.isEmpty && provider == .custom
        model = s.model
        buyerName = s.buyerName
        buyerTaxNo = s.buyerTaxNo
        excludeCitiesText = s.excludeCities.joined(separator: ", ")
    }

    /// Provider 切换：自动覆盖 base_url 和默认 model（除非用户手改过）
    private func handleProviderChange(_ p: LLMProvider) {
        if p == .custom {
            baseURL = ""
            availableModels = []
        } else {
            baseURL = p.defaultBaseURL
            manualBaseURL = false
            availableModels = []
        }
        model = p.defaultModel
    }

    private func save() {
        var s = state.settingsStore.settings
        s.apiKey = apiKey
        if let u = URL(string: baseURL) { s.baseURL = u }
        s.model = model.isEmpty ? provider.defaultModel : model
        s.buyerName = buyerName
        s.buyerTaxNo = buyerTaxNo
        s.excludeCities = excludeCitiesText
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        state.settingsStore.settings = s
        try? state.settingsStore.save()
        state.llmConfigured = !s.apiKey.isEmpty

        withAnimation { showSavedTip = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { showSavedTip = false }
        }
    }

    private func testConnection() async {
        isTesting = true
        testResult = ""
        defer { isTesting = false }
        let cfg = LLMConfig(
            apiKey: apiKey,
            baseURL: URL(string: baseURL) ?? LLMConfig.default.baseURL,
            model: model.isEmpty ? provider.defaultModel : model,
            timeout: 15
        )
        let client = LLMClient(config: cfg)
        do {
            let resp = try await client.chatJSON(
                system: "你是一个测试助手。请用 JSON 输出。",
                user: "请输出 {\"ok\": true}"
            )
            testResult = "✅ 连接成功。响应：\(String(describing: resp).prefix(80))"
            testColor = .green
            state.llmAvailable = true
        } catch {
            testResult = "❌ \(error.localizedDescription)"
            testColor = .red
            state.llmAvailable = false
        }
    }

    private func fetchModels() async {
        isFetchingModels = true
        defer { isFetchingModels = false }
        let cfg = LLMConfig(
            apiKey: apiKey,
            baseURL: URL(string: baseURL) ?? LLMConfig.default.baseURL,
            model: model,
            timeout: 15
        )
        do {
            let models = try await LLMClient(config: cfg).listModels()
            availableModels = models
            testResult = "✅ 拉到 \(models.count) 个模型"
            testColor = .green
        } catch {
            testResult = "❌ 拉模型失败：\(error.localizedDescription)"
            testColor = .red
        }
    }
}

/// 设置弹窗背景：macOS 26 让系统自动应用 Liquid Glass，旧版降级到 HUD 窗口材质
private struct SettingsSheetBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
        } else {
            content.background {
                VisualEffectView(material: .hudWindow, blendingMode: .behindWindow, alpha: 1.0)
            }
        }
    }
}

#Preview {
    SettingsView()
        .environment(AppState())
}
