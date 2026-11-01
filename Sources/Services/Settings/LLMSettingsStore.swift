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
import Observation

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

    /// 常驻地集合（小写，供 TripResolver 切分用）
    var homeCities: Set<String> {
        Set(excludeCities.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
    }

    var llmConfig: LLMConfig {
        LLMConfig(apiKey: apiKey, baseURL: baseURL, model: model, timeout: timeout)
    }
}

@MainActor
@Observable
final class LLMSettingsStore {
    var settings: LLMSettings

    private let envPath: URL

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
            .appendingPathComponent("Reimbursement", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        self.envPath = appSupport.appendingPathComponent(".env")

        var loaded = LLMSettingsStore.load(from: envPath)
        // API Key 以 Keychain 为准；.env 里的旧明文只作一次性迁移来源
        var needsMigration = false
        if let keychainKey = KeychainStore.get(account: KeychainStore.apiKeyAccount) {
            loaded.apiKey = keychainKey
        } else if !loaded.apiKey.isEmpty {
            needsMigration = true
        }
        self.settings = loaded

        if needsMigration {
            do {
                try save()
                FileHandle.standardError.write(Data("[Settings] LLM API Key 已从 .env 明文迁移到 Keychain\n".utf8))
            } catch {
                FileHandle.standardError.write(Data("[Settings] API Key 迁移 Keychain 失败（下次保存重试）：\(error.localizedDescription)\n".utf8))
            }
        }
    }

    /// 存盘：API Key 写 Keychain（.env 不再落明文）；其余配置写 .env，
    /// 已知键就地更新、未知键与注释行原样保留（旧实现会把未知键整段丢掉，与注释承诺不符）
    func save() throws {
        if settings.apiKey.isEmpty {
            KeychainStore.delete(account: KeychainStore.apiKeyAccount)
        } else {
            try KeychainStore.set(settings.apiKey, account: KeychainStore.apiKeyAccount)
        }
        let existing = (try? String(contentsOf: envPath, encoding: .utf8)) ?? ""
        let content = Self.mergedEnvContent(existing: existing, settings: settings)
        try content.write(to: envPath, atomically: true, encoding: .utf8)
    }

    /// .env 合并逻辑（纯函数，单测覆盖）：
    /// 已知键用新值就地替换（值为 nil 的可选键删行）；LLM_API_KEY 行一律移除；
    /// 其余行（注释/未知键）保持原样与原序；文件中没有的已知键追加到末尾
    static func mergedEnvContent(existing: String, settings: LLMSettings) -> String {
        let managed: [(key: String, value: String?)] = [
            ("LLM_BASE_URL", settings.baseURL.absoluteString),
            ("LLM_MODEL", settings.model),
            ("LLM_TIMEOUT", String(Int(settings.timeout))),
            ("BUYER_NAME", settings.buyerName.isEmpty ? nil : settings.buyerName),
            ("BUYER_TAX_NO", settings.buyerTaxNo.isEmpty ? nil : settings.buyerTaxNo),
            ("EXCLUDE_CITIES", settings.excludeCities.isEmpty ? nil : settings.excludeCities.joined(separator: ",")),
        ]
        let managedValues = Dictionary(uniqueKeysWithValues: managed.map { ($0.key, $0.value) })

        var lines: [String] = []
        var seen = Set<String>()
        for rawLine in existing.components(separatedBy: .newlines) {
            var probe = rawLine.trimmingCharacters(in: .whitespaces)
            if probe.hasPrefix("export ") {
                probe = String(probe.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
            }
            var handled = false
            if let eq = probe.firstIndex(of: "=") {
                let key = String(probe[..<eq]).trimmingCharacters(in: .whitespaces)
                if key == "LLM_API_KEY" {
                    handled = true   // 已迁 Keychain，明文行直接抹掉
                } else if let newValue = managedValues[key] {
                    seen.insert(key)
                    if let v = newValue { lines.append("\(key)=\(v)") }
                    handled = true
                }
            }
            if !handled, !(lines.isEmpty && rawLine.trimmingCharacters(in: .whitespaces).isEmpty) {
                lines.append(rawLine)
            }
        }
        if lines.first?.hasPrefix("#") != true {
            lines.insert("# 报销整理 LLM 配置", at: 0)
        }
        for (key, value) in managed where !seen.contains(key) {
            if let v = value { lines.append("\(key)=\(v)") }
        }
        return lines.joined(separator: "\n") + "\n"
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
