//
//  LLMPrompts.swift
//  报销整理Native
//
//  自动从 BillTypeFields 生成字段说明的 prompt。
//  对应 core/llm_prompts.py:_build_field_spec / FIELD_SPEC / FIELD_TYPE_HINTS / SYSTEM_PROMPT。
//
//  设计：所有票据类型共用同一份 prompt。LLM 看完 16 类型的字段表 + 顶层 Schema，
//  自己判断这张 OCR 文本属于哪一类、按那一类的字段填。
//

import Foundation

enum LLMPrompts {
    /// 自动生成字段说明（每个 BillType 一段）
    private static func fieldSpecMarkdown() -> String {
        var lines: [String] = []
        for bt in BillType.allCases {
            let s = BillTypeFields.spec(for: bt)
            if s.required.isEmpty && s.optional.isEmpty { continue }
            lines.append("### `\(bt.rawValue)`")
            if !s.required.isEmpty {
                lines.append("- 必填: " + s.required.map { "`\($0)`" }.joined(separator: ", "))
            }
            if !s.optional.isEmpty {
                lines.append("- 可选: " + s.optional.map { "`\($0)`" }.joined(separator: ", "))
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static let fieldSpec = fieldSpecMarkdown()

    private static let fieldTypeHints = """
### 通用字段类型说明
- 日期：字符串 `YYYY-MM-DD`（如 `2026-03-15`）
- 时间：字符串 `HH:mm`（24 小时制，如 `08:30`）
- 金额：数字，单位为元，保留 2 位小数（如 `553.00`）。如果原文是 `1,436.51` 转成 `1436.51`
- 整数（晚数、趟数等）：整数（如 `2`）
- 城市：去掉"省/市/区/县"后缀的纯城市名（如 `北京`、`上海`）
- 字符串：去除首尾空格；如无填 `null`
- 列表（items）：每项 `{name, quantity, unit_price, amount, tax_rate, tax_amount}`
- 缺失值用 `null`，**严禁**用空字符串或 "无"

### 各类型特殊字段
- `flight_no`：拼接形式如 `CA1234`（航空公司二字码 + 数字）
- `train_no`：如 `G7`、`D2341`（字母+数字）
- `cabin`：经济舱/商务舱/头等舱 等
- `seat_type`：二等座/一等座/商务座/硬卧/软卧/硬座 等
- `trip_period`：起止时间，如 `2026-03-03 09:00 至 2026-03-03 18:30`
- `id_no_masked`（火车票/机票）：保留原文脱敏形式，如 `1101**********1234`
- `passenger_name`：保留原文脱敏形式，如 `李*` 或 `LI/HAIDI`
- `provider`（网约车）：如 `滴滴出行`、`曹操出行`、`首汽约车`
- `fuel_grade`（加油费）：如 `92#`、`95#`、`0#(柴油)`
- `month`（通信费）：`YYYY-MM` 形式，如 `2026-03`
"""

    static let systemPrompt = """
# 角色
你是一名专业的中国票据识别专家，擅长从 OCR 文本中提取结构化信息，覆盖：
- 火车票、机票行程单、登机牌、高速路行程单、出租车/网约车
- 酒店水单（华住、锦江、首旅如家、亚朵、万豪、希尔顿、洲际、雅高、朗廷等所有品牌）
- 酒店增值税发票（普票/专票/电子发票；不同省市格式略有差异）
- 通用增值税普通发票 / 专用发票（电子发票/卷式发票）
- 滴滴/曹操/首汽等网约车行程单 + 电子发票
- 加油费、通行费（ETC）、餐饮、通信费发票

# 任务
阅读用户提供的「票据 OCR 文本」，识别票据类型，按下方 JSON Schema 输出结构化结果。

# 输出 Schema（顶层结构）
```json
{
  "receipt_type": "见下方票据类型枚举",
  "confidence": 0.0,
  "fields": { ... 类型相关字段 ... },
  "raw_text_excerpt": "OCR 原文前 500 字",
  "error": "识别失败原因；成功时为空字符串"
}
```

# 16 种票据类型
\(BillType.allCases.map { "- `\($0.rawValue)`（\($0.displayName)）" }.joined(separator: "\n"))

# 各类型字段清单
\(fieldSpec)

# 字段类型与示例
\(fieldTypeHints)

# 严格约束
- 只输出 JSON，不要任何解释、注释、Markdown 代码块
- 字段缺失用 `null`，**严禁**空字符串或 `"无"`
- 日期统一 `YYYY-MM-DD`；时间统一 `HH:mm`
- 金额统一数字（不要带 `¥`、`元`、千分位）
- `confidence` 是你对自己抽取结果的自评（0.0-1.0）；必填字段全缺失时 < 0.5
"""

    /// 组装 user message（OCR 文本 + 文件名提示）
    static func buildUserMessage(ocrText: String, filename: String = "") -> String {
        var parts: [String] = []
        if !filename.isEmpty {
            parts.append("文件名提示：`\(filename)`（可作为票据类型线索）")
        }
        parts.append("--- OCR 文本 ---")
        parts.append(ocrText)
        return parts.joined(separator: "\n\n")
    }
}
