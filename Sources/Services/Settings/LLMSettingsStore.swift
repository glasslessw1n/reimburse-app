//
//  LLMSettingsStore.swift
//  报销整理Native
//
//  LLM 配置持久化（.env 文件读写）。
//  对应 core/settings.py：手解析 KEY=VALUE，支持 export 前缀、引号、# 注释。
//
//  .env 位置：~/Library/Application Support/Reimbursement/.env
//

import Foundation

struct LLMSettings {
    var apiKey: String = ""
    var baseURL: URL = URL(string: "https://api.openai.com/v1")!
    var model: String = "gpt-4o-mini"
    var timeout: TimeInterval = 60

    /// 购方主数据（发票类型时强制覆盖 buyer 字段）
    var buyerName: String = ""
    var buyerTaxNo: String = ""

    /// 行程分组用的"常驻地"列表（trip 名里要去掉的城市）
    var excludeCities: [String] = []

    var llmConfig: LLMConfig {
        LLMConfig(apiKey: apiKey, baseURL: baseURL, model: model, timeout: timeout)
    }
}

@MainActor
final class LLMSettingsStore: ObservableObject {
    @Published var settings: LLMSettings

    private let envPath: URL

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
            .appendingPathComponent("Reimbursement", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        self.envPath = appSupport.appendingPathComponent(".env")

        self.settings = LLMSettingsStore.load(from: appSupport.appendingPathComponent(".env"))
    }

    /// 存盘到 .env（保留其它 key 的顺序）
    func save() throws {
        var lines: [String] = ["# 报销整理 LLM 配置"]
        lines.append("LLM_API_KEY=\(settings.apiKey)")
        lines.append("LLM_BASE_URL=\(settings.baseURL.absoluteString)")
        lines.append("LLM_MODEL=\(settings.model)")
        lines.append("LLM_TIMEOUT=\(Int(settings.timeout))")
        if !settings.buyerName.isEmpty {
            lines.append("BUYER_NAME=\(settings.buyerName)")
        }
        if !settings.buyerTaxNo.isEmpty {
            lines.append("BUYER_TAX_NO=\(settings.buyerTaxNo)")
        }
        if !settings.excludeCities.isEmpty {
            lines.append("EXCLUDE_CITIES=\(settings.excludeCities.joined(separator: ","))")
        }
        let content = lines.joined(separator: "\n") + "\n"
        try content.write(to: envPath, atomically: true, encoding: .utf8)
    }

    /// 同步读：进程启动时调用，把 .env 加载到环境变量
    func loadIntoProcessEnv() {
        setenv("LLM_API_KEY", settings.apiKey, 1)
        setenv("LLM_BASE_URL", settings.baseURL.absoluteString, 1)
        setenv("LLM_MODEL", settings.model, 1)
        setenv("BUYER_NAME", settings.buyerName, 1)
        setenv("BUYER_TAX_NO", settings.buyerTaxNo, 1)
        setenv("EXCLUDE_CITIES", settings.excludeCities.joined(separator: ","), 1)
    }

    // MARK: - .env 解析

    private static func load(from url: URL) -> LLMSettings {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return LLMSettings()
        }
        var s = LLMSettings()
        for (key, value) in parseEnv(raw) {
            switch key {
            case "LLM_API_KEY": s.apiKey = value
            case "LLM_BASE_URL": if let u = URL(string: value) { s.baseURL = u }
            case "LLM_MODEL": s.model = value
            case "LLM_TIMEOUT": if let t = TimeInterval(value) { s.timeout = t }
            case "BUYER_NAME": s.buyerName = value
            case "BUYER_TAX_NO": s.buyerTaxNo = value
            case "EXCLUDE_CITIES":
                s.excludeCities = value.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            default: break
            }
        }
        return s
    }

    /// 解析一行 `KEY=VALUE`：支持 # 注释、空行、`export ` 前缀、引号包裹
    private static func parseEnv(_ text: String) -> [(String, String)] {
        var result: [(String, String)] = []
        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") {
                line = String(line.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)

            // 去掉引号
            if (value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2) ||
               (value.hasPrefix("'")  && value.hasSuffix("'")  && value.count >= 2) {
                value = String(value.dropFirst().dropLast())
            }

            // 去掉尾部 # 注释（不在引号内的 # 前置空格）
            if !value.hasPrefix("\"") && !value.hasPrefix("'") {
                if let hashPos = value.range(of: " #") {
                    value = String(value[..<hashPos.lowerBound]).trimmingCharacters(in: .whitespaces)
                }
            }
            result.append((key, value))
        }
        return result
    }
}
