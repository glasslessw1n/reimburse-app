//
//  SettingsView.swift
//  报销整理Native
//
//  LLM 配置面板：
//  - Provider 下拉（DeepSeek / OpenAI / 月之暗面 / 智谱 / Ollama / vLLM / 自定义）
//  - 选 Provider 自动填 Base URL + 默认 model
//  - Base URL / API Key / Model 手填
//  - 测试连接 + 拉取模型列表
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState

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

    /// 手输框的固定宽度（也用于 Picker 下拉的参考宽度）
    private let inputFieldWidth: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题栏
            HStack {
                Text("LLM 设置")
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
                Button("关闭") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    sectionTitle("Provider")

                    // Provider 下拉：NSPopUpButton 包装（宽度严格 = inputFieldWidth）
                    HStack {
                        PopUpButtonWithLabel(
                            entries: LLMProvider.allCases.map { ($0, $0.rawValue) },
                            selection: $provider,
                            width: inputFieldWidth
                        )
                        .frame(width: inputFieldWidth, height: 24, alignment: .leading)
                        .onChange(of: provider) { _, new in
                            handleProviderChange(new)
                        }
                        Spacer()
                    }

                    sectionTitle("服务配置")

                    // Base URL：选了非自定义 provider 时锁定 + 显示对应 url
                    let baseURLIsLocked = (provider != .custom)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text("Base URL")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            if baseURLIsLocked {
                                Text("（随 Provider 自动填充）")
                                    .font(.system(size: 10))
                                    .foregroundColor(Color.gray.opacity(0.6))
                            }
                        }
                        TextField(baseURLIsLocked ? provider.defaultBaseURL : "https://your-provider.com/v1",
                                  text: $baseURL)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: inputFieldWidth)
                            .disabled(baseURLIsLocked)
                            .onChange(of: baseURL) { _, _ in
                                manualBaseURL = true
                            }
                    }

                    // API Key：右侧 eye 切换显示
                    VStack(alignment: .leading, spacing: 4) {
                        Text("API Key")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        HStack(spacing: 4) {
                            Group {
                                if apiKeyVisible {
                                    TextField("sk-...", text: $apiKey)
                                } else {
                                    SecureField("sk-...", text: $apiKey)
                                }
                            }
                            .textFieldStyle(.roundedBorder)
                            .frame(width: inputFieldWidth - 36)  // 留出按钮
                            Button {
                                apiKeyVisible.toggle()
                            } label: {
                                Image(systemName: apiKeyVisible ? "eye.slash" : "eye")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                    .frame(width: 24, height: 24)
                                    .background(
                                        RoundedRectangle(cornerRadius: 5)
                                            .fill(Color.gray.opacity(0.08))
                                    )
                            }
                            .buttonStyle(.plain)
                            .help(apiKeyVisible ? "隐藏 API Key" : "显示 API Key")
                        }
                    }

                    // Model + 拉取按钮（统一外观的 Picker，宽度 = inputFieldWidth）
                    HStack(alignment: .bottom, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Model")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            if availableModels.isEmpty {
                                TextField(provider.defaultModel, text: $model)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: inputFieldWidth)
                            } else {
                                // 把当前 model（不在列表里的）也作为第一项保留
                                let entries = ([(model, model)] +
                                    availableModels.map { ($0, $0) })
                                    .filter { !$0.0.isEmpty }
                                PopUpButtonWithLabel(
                                    entries: entries,
                                    selection: $model,
                                    width: inputFieldWidth
                                )
                                .frame(width: inputFieldWidth, height: 24, alignment: .leading)
                            }
                        }
                        Button {
                            Task { await fetchModels() }
                        } label: {
                            HStack(spacing: 4) {
                                if isFetchingModels { ProgressView().scaleEffect(0.5) }
                                Text(isFetchingModels ? "加载中" : "拉取列表")
                                    .font(.system(size: 11))
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(apiKey.isEmpty || baseURL.isEmpty || isFetchingModels)
                    }

                    if !availableModels.isEmpty {
                        Text("已发现 \(availableModels.count) 个模型")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    } else if !testResult.isEmpty && testColor == .red {
                        Text("提示：如果「拉取列表」报错，可手动在 Model 框输入模型名")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }

                    Divider().padding(.vertical, 8)

                    sectionTitle("购方主数据（增值税发票时强制覆盖 buyer 字段）")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("购方名称")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        TextField("XX 有限公司", text: $buyerName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: inputFieldWidth)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("购方税号")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        TextField("9111...", text: $buyerTaxNo)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: inputFieldWidth)
                    }

                    Divider().padding(.vertical, 8)

                    sectionTitle("常驻地（行程分组目录里要去掉的城市，逗号分隔）")
                    TextField("北京, 上海", text: $excludeCitiesText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: inputFieldWidth)

                    Divider().padding(.vertical, 8)

                    if !testResult.isEmpty {
                        Text(testResult)
                            .font(.system(size: 12))
                            .foregroundColor(testColor)
                    }

                    HStack {
                        Button {
                            Task { await testConnection() }
                        } label: {
                            HStack {
                                if isTesting { ProgressView().scaleEffect(0.5) }
                                Text(isTesting ? "测试中…" : "测试连接")
                            }
                            .frame(minWidth: 100)
                        }
                        .buttonStyle(.bordered)
                        .disabled(apiKey.isEmpty || baseURL.isEmpty || isTesting)

                        Spacer()

                        Button {
                            save()
                        } label: {
                            Text(showSavedTip ? "✓ 已保存" : "保存")
                                .frame(minWidth: 80)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(red: 0.98, green: 0.36, blue: 0.10))
                    }
                    .padding(.top, 8)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
        }
        .frame(width: 560, height: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { loadFromStore() }
    }

    // MARK: - 子视图

    private func sectionTitle(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.bottom, 4)
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
        // 选非 custom → 强制覆盖 base URL（即使是手改过）
        // 选 custom → 清空让用户填
        if p == .custom {
            baseURL = ""
            // 同时清空已拉取的模型列表，让 Model 回到 TextField
            availableModels = []
        } else {
            baseURL = p.defaultBaseURL
            manualBaseURL = false
            // 切到新 provider 时，原来的模型列表大概率对不上 → 清空
            availableModels = []
        }
        // model：覆盖为新 provider 的默认值（除非用户手填过别的）
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
        state.settingsStore.loadIntoProcessEnv()
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

#Preview {
    SettingsView()
        .environmentObject(AppState())
}
