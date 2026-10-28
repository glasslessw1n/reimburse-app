using System.Text.Json;
using System.Text.Json.Serialization;

namespace Reimbursement.Core.Models;

/// <summary>
/// 单张票据的扁平信息（对应 Swift BillInfo；Receipt 去掉 LLM 专属字段、加上 amount/date_range/cities 的版本），
/// 供打包/检查/填报共用。JSON schema 与 Swift 版 manifest 逐字兼容（键名 snake_case、空值省略规则一致）。
/// </summary>
[JsonConverter(typeof(BillInfoJsonConverter))]
public sealed class BillInfo
{
    /// <summary>稳定唯一 ID（不同票据绝不重复，也不随 amount 变化）。</summary>
    public string Uid { get; set; } = NewUid();
    public BillType BillType { get; set; }
    /// <summary>涉及的全部 MMDD（去重排序）。</summary>
    public List<string> DateMMDDs { get; set; } = new();
    /// <summary>入住-离店 / 行程起止（yyyy-MM-dd）。</summary>
    public (string Start, string End) DateRange { get; set; } = ("", "");
    public List<string> Cities { get; set; } = new();
    public string FromCity { get; set; } = "";
    public string ToCity { get; set; } = "";
    public double Amount { get; set; }
    public string SourceFile { get; set; } = "";
    public string TargetFilename { get; set; } = "";
    public string TargetSubdir { get; set; } = "";
    public bool NeedsReview { get; set; }
    public string ReviewReason { get; set; } = "";
    public double Confidence { get; set; } = 1.0;
    public Dictionary<string, string?> Fields { get; set; } = new();
    public string RawTextSnippet { get; set; } = "";
    public string Error { get; set; } = "";
    /// <summary>滴滴行程/发票配对字母（A/B/C…）；通行费序号也借用这个字段。</summary>
    public string DidiLetter { get; set; } = "";
    /// <summary>match 后的最终目标文件名（hotel invoice 关联 folio 后可能改名）。</summary>
    public string FinalTargetName { get; set; } = "";

    internal static string NewUid() => Guid.NewGuid().ToString().ToUpperInvariant();

    public BillInfo() { }

    public BillInfo(BillType billType, double amount = 0, string sourceFile = "",
        Dictionary<string, string?>? fields = null, bool needsReview = false,
        string reviewReason = "", double confidence = 1.0, string rawTextSnippet = "",
        string error = "")
    {
        BillType = billType;
        Amount = amount;
        SourceFile = sourceFile;
        Fields = fields ?? new Dictionary<string, string?>();
        NeedsReview = needsReview;
        ReviewReason = reviewReason;
        Confidence = confidence;
        RawTextSnippet = rawTextSnippet;
        Error = error;
        DeriveFromFields();
    }

    public string? F(string key) => Fields.TryGetValue(key, out var v) ? v : null;

    /// <summary>从 fields 派生 DateMMDDs / DateRange / Cities（与 Swift init 逐条对应）。</summary>
    public void DeriveFromFields()
    {
        var mmdds = new List<string>();
        foreach (var k in new[] { "departure_date", "check_in_date", "issue_date" })
        {
            if (F(k) is { Length: >= 10 } d)
                mmdds.Add(d[^5..].Replace("-", ""));
        }
        if (F("check_out_date") is { Length: >= 10 } co)
            mmdds.Add(co[^5..].Replace("-", ""));
        DateMMDDs = mmdds.Distinct().OrderBy(x => x, StringComparer.Ordinal).ToList();

        var ci = F("check_in_date");
        var coo = F("check_out_date");
        if (ci != null)
            DateRange = (Take(ci, 10), Take(coo ?? ci, 10));
        else if (F("departure_date") is { } dep)
            DateRange = (Take(dep, 10), Take(dep, 10));
        else if (F("issue_date") is { } iss)
            DateRange = (Take(iss, 10), Take(iss, 10));

        var cs = new List<string>();
        foreach (var k in new[] { "origin_city", "destination_city", "city" })
        {
            if (F(k) is { Length: > 0 } c) cs.Add(c);
        }
        Cities = cs;
        FromCity = F("origin_city") ?? "";
        ToCity = F("destination_city") ?? "";
    }

    internal static string Take(string s, int n) => s.Length <= n ? s : s[..n];

    /// <summary>值拷贝（对应 Swift struct 赋值语义；Fields 做深拷贝）。</summary>
    public BillInfo Clone()
    {
        var c = (BillInfo)MemberwiseClone();
        c.DateMMDDs = new List<string>(DateMMDDs);
        c.Cities = new List<string>(Cities);
        c.Fields = new Dictionary<string, string?>(Fields);
        return c;
    }
}

/// <summary>
/// BillInfo 的 JSON 编解码，与 Swift Codable 对齐：
/// 解码全部带缺省（老 manifest 无 uid 时生成新值）；编码省略空字符串/false/空 fields，且 fields 剔除 null 值。
/// </summary>
public sealed class BillInfoJsonConverter : JsonConverter<BillInfo>
{
    public override BillInfo Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        using var doc = JsonDocument.ParseValue(ref reader);
        var root = doc.RootElement;
        var b = new BillInfo();
        if (root.ValueKind != JsonValueKind.Object) return b;

        b.Uid = Str(root, "uid") is { Length: > 0 } uid ? uid : BillInfo.NewUid();
        b.BillType = BillTypeInfo.FromRaw(Str(root, "bill_type"));
        b.DateMMDDs = StrList(root, "date_mmdds");
        if (root.TryGetProperty("date_range", out var dr) && dr.ValueKind == JsonValueKind.Array)
        {
            var arr = dr.EnumerateArray().Select(e => e.ValueKind == JsonValueKind.String ? e.GetString() ?? "" : "").ToList();
            if (arr.Count >= 2) b.DateRange = (arr[0], arr[1]);
        }
        b.Cities = StrList(root, "cities");
        b.FromCity = Str(root, "from_city") ?? "";
        b.ToCity = Str(root, "to_city") ?? "";
        b.Amount = Num(root, "amount") ?? 0;
        b.SourceFile = Str(root, "source_file") ?? "";
        b.TargetFilename = Str(root, "target_filename") ?? "";
        b.TargetSubdir = Str(root, "target_subdir") ?? "";
        b.NeedsReview = Bool(root, "needs_review") ?? false;
        b.ReviewReason = Str(root, "review_reason") ?? "";
        b.Confidence = Num(root, "confidence") ?? 1.0;
        if (root.TryGetProperty("fields", out var f)) b.Fields = JsonNormalize.ParseFields(f);
        b.RawTextSnippet = Str(root, "raw_text_snippet") ?? "";
        b.Error = Str(root, "error") ?? "";
        b.DidiLetter = Str(root, "didi_letter") ?? "";
        b.FinalTargetName = Str(root, "_final_target_name") ?? "";
        return b;
    }

    private static string? Str(JsonElement root, string key) =>
        root.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    private static double? Num(JsonElement root, string key) =>
        root.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetDouble() : null;

    private static bool? Bool(JsonElement root, string key) =>
        root.TryGetProperty(key, out var v) && (v.ValueKind == JsonValueKind.True || v.ValueKind == JsonValueKind.False)
            ? v.GetBoolean() : null;

    private static List<string> StrList(JsonElement root, string key)
    {
        var list = new List<string>();
        if (root.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.Array)
            foreach (var e in v.EnumerateArray())
                if (e.ValueKind == JsonValueKind.String) list.Add(e.GetString() ?? "");
        return list;
    }

    public override void Write(Utf8JsonWriter writer, BillInfo b, JsonSerializerOptions options)
    {
        writer.WriteStartObject();
        writer.WriteString("uid", b.Uid);
        writer.WriteString("bill_type", b.BillType.ToRaw());
        writer.WritePropertyName("date_mmdds");
        writer.WriteStartArray();
        foreach (var s in b.DateMMDDs) writer.WriteStringValue(s);
        writer.WriteEndArray();
        writer.WritePropertyName("date_range");
        writer.WriteStartArray();
        writer.WriteStringValue(b.DateRange.Start);
        writer.WriteStringValue(b.DateRange.End);
        writer.WriteEndArray();
        writer.WritePropertyName("cities");
        writer.WriteStartArray();
        foreach (var s in b.Cities) writer.WriteStringValue(s);
        writer.WriteEndArray();
        if (b.FromCity.Length > 0) writer.WriteString("from_city", b.FromCity);
        if (b.ToCity.Length > 0) writer.WriteString("to_city", b.ToCity);
        writer.WriteNumber("amount", b.Amount);
        writer.WriteString("source_file", b.SourceFile);
        if (b.TargetFilename.Length > 0) writer.WriteString("target_filename", b.TargetFilename);
        if (b.TargetSubdir.Length > 0) writer.WriteString("target_subdir", b.TargetSubdir);
        if (b.NeedsReview) writer.WriteBoolean("needs_review", true);
        if (b.ReviewReason.Length > 0) writer.WriteString("review_reason", b.ReviewReason);
        writer.WriteNumber("confidence", b.Confidence);
        var compact = b.Fields.Where(kv => kv.Value != null).ToList();
        if (compact.Count > 0)
        {
            writer.WritePropertyName("fields");
            writer.WriteStartObject();
            foreach (var (k, v) in compact) writer.WriteString(k, v);
            writer.WriteEndObject();
        }
        if (b.RawTextSnippet.Length > 0) writer.WriteString("raw_text_snippet", b.RawTextSnippet);
        if (b.Error.Length > 0) writer.WriteString("error", b.Error);
        if (b.DidiLetter.Length > 0) writer.WriteString("didi_letter", b.DidiLetter);
        if (b.FinalTargetName.Length > 0) writer.WriteString("_final_target_name", b.FinalTargetName);
        writer.WriteEndObject();
    }
}
