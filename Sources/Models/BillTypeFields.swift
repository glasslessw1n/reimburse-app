//
//  BillTypeFields.swift
//  报销整理Native
//
//  每种票据的核心字段清单（对应 core/receipt_schema.py:RECEIPT_TYPE_FIELDS）。
//
//  字段含义：
//  - required: 必填，LLM 必须给出值（缺失会降低 confidence）
//  - optional: 可选
//  - sortable: 可作为排序/分组键（日期/城市/金额）
//  - fileNamePart: 是否参与生成文件名
//

import Foundation

struct BillFieldSpec: Sendable {
    let required: [String]
    let optional: [String]
    let sortable: [String]
    let fileNamePart: [String]
}

enum BillTypeFields {
    static let all: [BillType: BillFieldSpec] = [
        .trainTicket: BillFieldSpec(
            required: ["departure_date", "origin_city", "destination_city", "amount"],
            optional: ["train_no", "departure_time", "seat_type", "ticket_no", "passenger_name", "id_no_masked"],
            sortable: ["departure_date", "amount"],
            fileNamePart: ["departure_date", "train_no", "origin_city", "destination_city", "amount"]
        ),
        .flightItinerary: BillFieldSpec(
            required: ["departure_date", "origin_city", "destination_city", "amount"],
            optional: ["flight_no", "departure_time", "origin_airport", "destination_airport",
                       "cabin", "fare", "tax", "ticket_no", "passenger_name"],
            sortable: ["departure_date", "amount"],
            fileNamePart: ["departure_date", "flight_no", "origin_city", "destination_city", "amount"]
        ),
        .boardingPass: BillFieldSpec(
            required: ["departure_date"],
            optional: ["flight_no", "origin_city", "destination_city", "seat", "passenger_name"],
            sortable: ["departure_date"],
            fileNamePart: ["departure_date", "flight_no", "origin_city", "destination_city"]
        ),
        .selfDriveSheet: BillFieldSpec(
            required: ["departure_date", "origin_city", "destination_city"],
            optional: ["distance_km", "departure_time"],
            sortable: ["departure_date"],
            fileNamePart: ["departure_date", "origin_city", "destination_city"]
        ),
        .taxiTransport: BillFieldSpec(
            required: ["amount"],
            optional: ["departure_date", "origin_city", "destination_city", "merchant_name"],
            sortable: ["departure_date", "amount"],
            fileNamePart: ["departure_date", "merchant_name", "amount"]
        ),
        .didiTrip: BillFieldSpec(
            required: ["amount", "departure_date"],
            optional: ["ride_count", "origin_city", "destination_city", "total_km", "trip_period"],
            sortable: ["departure_date", "amount"],
            fileNamePart: ["departure_date", "provider", "amount"]
        ),
        .didiInvoice: BillFieldSpec(
            required: ["amount", "issue_date"],
            optional: ["invoice_no", "provider"],
            sortable: ["issue_date", "amount"],
            fileNamePart: ["issue_date", "provider", "amount"]
        ),
        .hotelFolio: BillFieldSpec(
            required: ["hotel_name", "check_in_date", "check_out_date", "city", "amount"],
            optional: ["nights", "room_type", "room_no", "guest_name", "address", "brand"],
            sortable: ["check_in_date", "check_out_date", "amount"],
            fileNamePart: ["check_in_date", "hotel_name", "nights", "amount"]
        ),
        .hotelInvoice: BillFieldSpec(
            required: ["hotel_name", "issue_date", "seller_name", "amount"],
            optional: ["check_in_date", "check_out_date", "city", "nights",
                       "invoice_no", "invoice_code", "seller_tax_no",
                       "amount_excl_tax", "tax_amount"],
            sortable: ["issue_date", "amount"],
            fileNamePart: ["issue_date", "seller_name", "amount"]
        ),
        .vatInvoiceGeneral: BillFieldSpec(
            required: ["issue_date", "seller_name", "amount"],
            optional: ["invoice_no", "invoice_code", "buyer_name", "buyer_tax_no",
                       "category", "amount_excl_tax", "tax_amount", "items"],
            sortable: ["issue_date", "amount"],
            fileNamePart: ["issue_date", "seller_name", "amount"]
        ),
        .vatInvoiceSpecial: BillFieldSpec(
            required: ["issue_date", "seller_name", "buyer_name", "amount"],
            optional: ["invoice_no", "invoice_code", "seller_tax_no", "buyer_tax_no",
                       "category", "amount_excl_tax", "tax_amount", "items"],
            sortable: ["issue_date", "amount"],
            fileNamePart: ["issue_date", "seller_name", "amount"]
        ),
        .gasInvoice: BillFieldSpec(
            required: ["amount", "issue_date"],
            optional: ["merchant_name", "fuel_grade"],
            sortable: ["issue_date", "amount"],
            fileNamePart: ["issue_date", "merchant_name", "amount"]
        ),
        .tollInvoice: BillFieldSpec(
            required: ["amount", "issue_date"],
            optional: ["origin_city", "destination_city", "sequence"],
            sortable: ["issue_date", "amount"],
            fileNamePart: ["issue_date", "amount"]
        ),
        .dining: BillFieldSpec(
            required: ["amount", "issue_date"],
            optional: ["merchant_name", "category", "headcount"],
            sortable: ["issue_date", "amount"],
            fileNamePart: ["issue_date", "merchant_name", "amount"]
        ),
        .telecom: BillFieldSpec(
            required: ["amount", "issue_date"],
            optional: ["carrier", "phone_no", "month"],
            sortable: ["issue_date", "amount"],
            fileNamePart: ["month", "carrier", "amount"]
        ),
        .other: BillFieldSpec(
            required: [],
            optional: ["amount", "issue_date", "merchant_name"],
            sortable: [],
            fileNamePart: ["issue_date", "amount"]
        ),
    ]

    static func spec(for type: BillType) -> BillFieldSpec {
        all[type] ?? BillFieldSpec(required: [], optional: [], sortable: [], fileNamePart: [])
    }

    /// 所有字段名（required + optional，去重）
    static func allFields(for type: BillType) -> [String] {
        let s = spec(for: type)
        return Array(Set(s.required + s.optional)).sorted()
    }
}
