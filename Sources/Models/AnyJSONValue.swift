//
//  AnyJSONValue.swift
//  报销整理Native
//
//  通用 JSON value 解码器，用于把 LLM 返回的混合类型 fields 归一化为 String。
//  LLM 输出可能是：string / number / boolean / null。
//

import Foundation

enum AnyJSONValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([AnyJSONValue])
    case object([String: AnyJSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let d = try? c.decode(Double.self) {
            self = .number(d)
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let arr = try? c.decode([AnyJSONValue].self) {
            self = .array(arr)
        } else if let obj = try? c.decode([String: AnyJSONValue].self) {
            self = .object(obj)
        } else {
            self = .null
        }
    }

    /// 归一化为 String?（数字保留小数；bool 转 "true"/"false"；array/object 降级为 nil）
    var toOptionalString: String? {
        switch self {
        case .string(let s): return s
        case .number(let d):
            // 整数不带小数点
            if d.truncatingRemainder(dividingBy: 1) == 0 && abs(d) < 1e15 {
                return String(Int(d))
            }
            return String(d)
        case .bool(let b): return b ? "true" : "false"
        case .null: return nil
        case .array, .object: return nil  // 复杂类型丢弃（M9.5 再处理 items 列表）
        }
    }
}
