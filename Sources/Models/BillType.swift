//
//  BillType.swift
//  报销整理Native
//
//  16 种票据类型枚举（对应 core/receipt_schema.py:BillType）。
//  新增类型时：
//    1) 在本枚举加 case
//    2) 在 BillTypeFields 加一项
//    3) 在 LLMPrompts 的字段说明会自动同步
//

import Foundation

enum BillType: String, Codable, CaseIterable, Sendable {
    // 交通
    case trainTicket = "train_ticket"               // 火车票
    case flightItinerary = "flight_itinerary"       // 机票行程单
    case boardingPass = "boarding_pass"             // 登机牌
    case selfDriveSheet = "self_drive_sheet"       // 高速路行程单
    case taxiTransport = "taxi_transport"           // 出租车/公交/地铁
    // 网约车
    case didiTrip = "didi_trip"                     // 滴滴行程单
    case didiInvoice = "didi_invoice"               // 滴滴电子发票
    // 酒店
    case hotelFolio = "hotel_folio"                 // 酒店水单/账单
    case hotelInvoice = "hotel_invoice"             // 酒店增值税发票
    // 通用发票
    case vatInvoiceGeneral = "vat_invoice_general"  // 增值税普通发票
    case vatInvoiceSpecial = "vat_invoice_special"  // 增值税专用发票
    // 其他
    case gasInvoice = "gas_invoice"                 // 加油费
    case tollInvoice = "toll_invoice"               // 通行费
    case dining = "dining"                           // 餐饮
    case telecom = "telecom"                        // 通信
    case other = "other"                            // 其他/未识别

    /// 中文显示名（对应 web 版的 _typeLabel）
    var displayName: String {
        switch self {
        case .trainTicket: return "火车票"
        case .flightItinerary: return "机票行程单"
        case .boardingPass: return "登机牌"
        case .selfDriveSheet: return "高速路行程单"
        case .taxiTransport: return "出租/公交/地铁"
        case .didiTrip: return "滴滴行程单"
        case .didiInvoice: return "滴滴发票"
        case .hotelFolio: return "酒店水单"
        case .hotelInvoice: return "酒店发票"
        case .vatInvoiceGeneral: return "增值税普票"
        case .vatInvoiceSpecial: return "增值税专票"
        case .gasInvoice: return "加油费"
        case .tollInvoice: return "通行费"
        case .dining: return "餐饮"
        case .telecom: return "通信"
        case .other: return "其他"
        }
    }

    /// 配色 CSS var 名（web 版 _typeClass 用）
    /// 后续 UI 渲染时映射到 SwiftUI Color
    var cssClass: String {
        switch self {
        case .trainTicket, .flightItinerary, .boardingPass:
            return "transport"
        case .selfDriveSheet, .taxiTransport, .didiTrip, .didiInvoice:
            return "ride"
        case .hotelFolio, .hotelInvoice:
            return "hotel"
        case .vatInvoiceGeneral, .vatInvoiceSpecial:
            return "invoice"
        case .gasInvoice, .tollInvoice:
            return "fuel"
        case .dining, .telecom:
            return "misc"
        case .other:
            return "other"
        }
    }
}
