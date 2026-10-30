namespace Reimbursement.Core.Models;

/// <summary>
/// 票据类型（对应 Swift BillType / Python BillType）。
/// 新增类型时：1) 本枚举加成员 2) BillTypeFields 加一项 3) LLMPrompts 的字段说明会自动同步。
/// </summary>
public enum BillType
{
    TrainTicket,
    FlightItinerary,
    BoardingPass,
    SelfDriveSheet,
    TaxiTransport,
    DidiTrip,
    DidiInvoice,
    HotelFolio,
    HotelInvoice,
    GasInvoice,
    TollInvoice,
    Dining,
    Telecom,
    Other,
}

public static class BillTypeInfo
{
    public static string ToRaw(this BillType t) => t switch
    {
        BillType.TrainTicket => "train_ticket",
        BillType.FlightItinerary => "flight_itinerary",
        BillType.BoardingPass => "boarding_pass",
        BillType.SelfDriveSheet => "self_drive_sheet",
        BillType.TaxiTransport => "taxi_transport",
        BillType.DidiTrip => "didi_trip",
        BillType.DidiInvoice => "didi_invoice",
        BillType.HotelFolio => "hotel_folio",
        BillType.HotelInvoice => "hotel_invoice",
        BillType.GasInvoice => "gas_invoice",
        BillType.TollInvoice => "toll_invoice",
        BillType.Dining => "dining",
        BillType.Telecom => "telecom",
        _ => "other",
    };

    /// <summary>未知类型落 Other（与 Swift `BillType(rawValue:) ?? .other` 一致）。</summary>
    public static BillType FromRaw(string? raw) => raw switch
    {
        "train_ticket" => BillType.TrainTicket,
        "flight_itinerary" => BillType.FlightItinerary,
        "boarding_pass" => BillType.BoardingPass,
        "self_drive_sheet" => BillType.SelfDriveSheet,
        "taxi_transport" => BillType.TaxiTransport,
        "didi_trip" => BillType.DidiTrip,
        "didi_invoice" => BillType.DidiInvoice,
        "hotel_folio" => BillType.HotelFolio,
        "hotel_invoice" => BillType.HotelInvoice,
        "gas_invoice" => BillType.GasInvoice,
        "toll_invoice" => BillType.TollInvoice,
        "dining" => BillType.Dining,
        "telecom" => BillType.Telecom,
        _ => BillType.Other,
    };

    public static string DisplayName(this BillType t) => t switch
    {
        BillType.TrainTicket => "火车票",
        BillType.FlightItinerary => "机票行程单",
        BillType.BoardingPass => "登机牌",
        BillType.SelfDriveSheet => "高速路行程单",
        BillType.TaxiTransport => "出租/公交/地铁",
        BillType.DidiTrip => "滴滴行程单",
        BillType.DidiInvoice => "滴滴发票",
        BillType.HotelFolio => "酒店水单",
        BillType.HotelInvoice => "酒店发票",
        BillType.GasInvoice => "加油费",
        BillType.TollInvoice => "通行费",
        BillType.Dining => "餐饮",
        BillType.Telecom => "通信",
        _ => "其他",
    };

    /// <summary>配色分组（对应 web 版 _typeClass / Swift cssClass），UI 渲染时映射到主题色。</summary>
    public static string CssClass(this BillType t) => t switch
    {
        BillType.TrainTicket or BillType.FlightItinerary or BillType.BoardingPass => "transport",
        BillType.SelfDriveSheet or BillType.TaxiTransport or BillType.DidiTrip or BillType.DidiInvoice => "ride",
        BillType.HotelFolio or BillType.HotelInvoice => "hotel",
        BillType.GasInvoice or BillType.TollInvoice => "fuel",
        BillType.Dining or BillType.Telecom => "misc",
        _ => "other",
    };

    public static IEnumerable<BillType> All => Enum.GetValues<BillType>();
}
