namespace Reimbursement.Core.Models;

/// <summary>
/// 每种票据的字段清单（对应 Swift BillTypeFields / Python RECEIPT_TYPE_FIELDS）。
/// required: 必填（缺失降低覆盖度）；optional: 可选；sortable: 排序/分组键；fileNamePart: 参与文件名生成。
/// </summary>
public sealed record BillFieldSpec(
    IReadOnlyList<string> Required,
    IReadOnlyList<string> Optional,
    IReadOnlyList<string> Sortable,
    IReadOnlyList<string> FileNamePart);

public static class BillTypeFields
{
    private static BillFieldSpec S(string[] r, string[] o, string[] s, string[] f) => new(r, o, s, f);

    public static readonly IReadOnlyDictionary<BillType, BillFieldSpec> All =
        new Dictionary<BillType, BillFieldSpec>
        {
            [BillType.TrainTicket] = S(
                ["departure_date", "origin_city", "destination_city", "amount"],
                ["train_no", "departure_time", "seat_type", "ticket_no", "passenger_name", "id_no_masked"],
                ["departure_date", "amount"],
                ["departure_date", "train_no", "origin_city", "destination_city", "amount"]),
            [BillType.FlightItinerary] = S(
                ["departure_date", "origin_city", "destination_city", "amount"],
                ["flight_no", "departure_time", "origin_airport", "destination_airport",
                 "cabin", "fare", "tax", "ticket_no", "passenger_name"],
                ["departure_date", "amount"],
                ["departure_date", "flight_no", "origin_city", "destination_city", "amount"]),
            [BillType.BoardingPass] = S(
                ["departure_date"],
                ["flight_no", "origin_city", "destination_city", "seat", "passenger_name"],
                ["departure_date"],
                ["departure_date", "origin_city", "destination_city"]),
            [BillType.SelfDriveSheet] = S(
                ["departure_date", "origin_city", "destination_city"],
                ["distance_km", "departure_time"],
                ["departure_date"],
                ["departure_date", "origin_city", "destination_city"]),
            [BillType.TaxiTransport] = S(
                ["amount"],
                ["departure_date", "origin_city", "destination_city", "merchant_name"],
                ["departure_date", "amount"],
                ["departure_date", "merchant_name", "amount"]),
            [BillType.DidiTrip] = S(
                ["amount", "departure_date"],
                ["ride_count", "origin_city", "destination_city", "total_km", "trip_period"],
                ["departure_date", "amount"],
                ["departure_date", "provider", "amount"]),
            [BillType.DidiInvoice] = S(
                ["amount", "issue_date"],
                ["invoice_no", "provider"],
                ["issue_date", "amount"],
                ["issue_date", "provider", "amount"]),
            [BillType.HotelFolio] = S(
                ["hotel_name", "check_in_date", "check_out_date", "city", "amount"],
                ["nights", "room_type", "room_no", "guest_name", "address", "brand"],
                ["check_in_date", "check_out_date", "amount"],
                ["check_in_date", "hotel_name", "nights", "amount"]),
            [BillType.HotelInvoice] = S(
                ["hotel_name", "issue_date", "seller_name", "amount"],
                ["check_in_date", "check_out_date", "city", "nights",
                 "invoice_no", "invoice_code", "seller_tax_no",
                 "amount_excl_tax", "tax_amount", "invoice_form"],
                ["issue_date", "amount"],
                ["issue_date", "seller_name", "amount"]),
            [BillType.GasInvoice] = S(
                ["amount", "issue_date"],
                ["merchant_name", "fuel_grade"],
                ["issue_date", "amount"],
                ["issue_date", "merchant_name", "amount"]),
            [BillType.TollInvoice] = S(
                ["amount", "issue_date"],
                ["origin_city", "destination_city", "sequence"],
                ["issue_date", "amount"],
                ["issue_date", "amount"]),
            [BillType.Dining] = S(
                ["amount", "issue_date"],
                ["merchant_name", "category", "headcount"],
                ["issue_date", "amount"],
                ["issue_date", "merchant_name", "amount"]),
            [BillType.Telecom] = S(
                ["amount", "issue_date"],
                ["carrier", "phone_no", "month"],
                ["issue_date", "amount"],
                ["month", "carrier", "amount"]),
            [BillType.Other] = S(
                [],
                ["amount", "issue_date", "merchant_name", "invoice_form"],
                [],
                ["issue_date", "amount"]),
        };

    public static BillFieldSpec Spec(BillType type) =>
        All.TryGetValue(type, out var s) ? s : new BillFieldSpec([], [], [], []);

    /// <summary>所有字段名（required + optional，去重后排序，与 Swift allFields 一致）。</summary>
    public static IReadOnlyList<string> AllFields(BillType type)
    {
        var spec = Spec(type);
        return spec.Required.Concat(spec.Optional).Distinct().OrderBy(x => x, StringComparer.Ordinal).ToList();
    }
}
