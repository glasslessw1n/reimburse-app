using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Reimbursement.Core.Models;

/// <summary>
/// LLM 识别单张票据后的标准输出（对应 Swift Receipt / Python Receipt）。
/// 金额/日期在 fields 里统一为字符串，避免 LLM 输出 553.00 vs 553 的浮点误差，下游需要时再 parse。
/// Error 非空表示识别失败。
/// </summary>
[JsonConverter(typeof(ReceiptJsonConverter))]
public sealed class Receipt
{
    public BillType ReceiptType { get; set; } = BillType.Other;
    public double Confidence { get; set; }
    public Dictionary<string, string?> Fields { get; set; } = new();
    public string RawTextExcerpt { get; set; } = "";
    public string RecognizedAt { get; set; } = "";
    public string SourceFile { get; set; } = "";
    public string Error { get; set; } = "";

    public Receipt() { }

    public Receipt(BillType receiptType, double confidence = 0.0,
        Dictionary<string, string?>? fields = null, string rawTextExcerpt = "",
        string recognizedAt = "", string sourceFile = "", string error = "")
    {
        ReceiptType = receiptType;
        Confidence = confidence;
        Fields = fields ?? new Dictionary<string, string?>();
        RawTextExcerpt = rawTextExcerpt;
        RecognizedAt = recognizedAt;
        SourceFile = sourceFile;
        Error = error;
    }

    /// <summary>字段值（不存在或显式 null 都返回 null，与 Swift field(_:) 一致）。</summary>
    public string? Field(string key) =>
        Fields.TryGetValue(key, out var v) ? v : null;

    /// <summary>必填字段覆盖度 0-1（显式 null 不算命中；无必填字段时为 1）。</summary>
    public double RequiredCoverage
    {
        get
        {
            var req = BillTypeFields.Spec(ReceiptType).Required;
            if (req.Count == 0) return 1.0;
            var hit = req.Count(k => Field(k) != null);
            return (double)hit / req.Count;
        }
    }

    /// <summary>真正需要人工复核：error 非空、置信太低、或必填字段严重缺失。</summary>
    public bool NeedsReview => Error.Length > 0 || Confidence < 0.5 || RequiredCoverage < 0.5;

    /// <summary>行程分组用日期：departure_date / check_in_date / issue_date 优先序。</summary>
    public string? TripDate => Field("departure_date") ?? Field("check_in_date") ?? Field("issue_date");

    /// <summary>行程分组用城市：origin_city / city 优先序。</summary>
    public string? TripCity => Field("origin_city") ?? Field("city");
}

/// <summary>
/// Receipt 的 JSON 编解码（snake_case 键名，与 Swift Codable 实现逐条对齐）：
/// 解码容错——confidence 可为数字或字符串；fields 值可为数字/布尔/null（归一化为字符串）；
/// 编码时剔除 null 字段、error 为空不写出。
/// </summary>
public sealed class ReceiptJsonConverter : JsonConverter<Receipt>
{
    public override Receipt Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        using var doc = JsonDocument.ParseValue(ref reader);
        var root = doc.RootElement;
        var r = new Receipt();
        if (root.ValueKind != JsonValueKind.Object) return r;

        if (root.TryGetProperty("receipt_type", out var t) && t.ValueKind == JsonValueKind.String)
            r.ReceiptType = BillTypeInfo.FromRaw(t.GetString());

        if (root.TryGetProperty("confidence", out var c))
        {
            if (c.ValueKind == JsonValueKind.Number) r.Confidence = c.GetDouble();
            else if (c.ValueKind == JsonValueKind.String &&
                     double.TryParse(c.GetString(), NumberStyles.Float, CultureInfo.InvariantCulture, out var d))
                r.Confidence = d;
        }

        if (root.TryGetProperty("fields", out var f))
            r.Fields = JsonNormalize.ParseFields(f);

        r.RawTextExcerpt = GetStr(root, "raw_text_excerpt");
        r.RecognizedAt = GetStr(root, "recognized_at");
        r.SourceFile = GetStr(root, "source_file");
        r.Error = GetStr(root, "error");
        return r;
    }

    private static string GetStr(JsonElement root, string key) =>
        root.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? "" : "";

    public override void Write(Utf8JsonWriter writer, Receipt value, JsonSerializerOptions options)
    {
        writer.WriteStartObject();
        writer.WriteString("receipt_type", value.ReceiptType.ToRaw());
        writer.WriteNumber("confidence", value.Confidence);
        writer.WritePropertyName("fields");
        writer.WriteStartObject();
        foreach (var (k, v) in value.Fields)
        {
            if (v == null) continue;
            writer.WriteString(k, v);
        }
        writer.WriteEndObject();
        writer.WriteString("raw_text_excerpt", value.RawTextExcerpt);
        writer.WriteString("recognized_at", value.RecognizedAt);
        writer.WriteString("source_file", value.SourceFile);
        if (value.Error.Length > 0) writer.WriteString("error", value.Error);
        writer.WriteEndObject();
    }
}
