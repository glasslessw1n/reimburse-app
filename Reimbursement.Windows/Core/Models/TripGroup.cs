using System.Text.Json;
using System.Text.Json.Serialization;

namespace Reimbursement.Core.Models;

/// <summary>行程分组（对应 Swift TripGroup）。</summary>
[JsonConverter(typeof(TripGroupJsonConverter))]
public sealed class TripGroup
{
    /// <summary>稳定唯一 ID（两个同日行程不再共用同一个 key）。</summary>
    public string Uid { get; set; } = BillInfo.NewUid();
    public string Key { get; set; } = "";
    public string FirstMMDD { get; set; } = "";
    public string LastMMDD { get; set; } = "";
    public List<string> Cities { get; set; } = new();
    public List<BillInfo> Bills { get; set; } = new();

    public TripGroup() { }

    public TripGroup(string key, string firstMMDD, string lastMMDD,
        List<string>? cities = null, List<BillInfo>? bills = null)
    {
        Key = key;
        FirstMMDD = firstMMDD;
        LastMMDD = lastMMDD;
        Cities = cities ?? new List<string>();
        Bills = bills ?? new List<BillInfo>();
    }

    /// <summary>目录名：`MMDD-MMDD 城市1 城市2`（单日只写一个 MMDD；城市过滤伪城市并相邻去重）。</summary>
    public string Dirname
    {
        get
        {
            var head = FirstMMDD == LastMMDD ? FirstMMDD : $"{FirstMMDD}-{LastMMDD}";
            var deduped = new List<string>();
            foreach (var c in Cities)
            {
                if (IsRealCity(c) && (deduped.Count == 0 || deduped[^1] != c))
                    deduped.Add(c);
            }
            var cityStr = string.Join(" ", deduped);
            return cityStr.Length == 0 ? head : $"{head} {cityStr}";
        }
    }

    public static bool IsRealCity(string name)
    {
        if (name.Length == 0) return false;
        if (name.Contains(' ')) return false;
        if (name.Any(ch => (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z'))) return false;
        if (name.Length > 6) return false;
        return true;
    }
}

public sealed class TripGroupJsonConverter : JsonConverter<TripGroup>
{
    public override TripGroup Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        using var doc = JsonDocument.ParseValue(ref reader);
        var root = doc.RootElement;
        var g = new TripGroup();
        if (root.ValueKind != JsonValueKind.Object) return g;

        string? Get(string k) =>
            root.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

        g.Key = Get("key") ?? "";
        // 老 manifest 没有 uid → 用 key 兜底，保证向后兼容
        g.Uid = Get("uid") ?? g.Key;
        g.FirstMMDD = Get("first_mmdd") ?? "";
        g.LastMMDD = Get("last_mmdd") ?? "";
        if (root.TryGetProperty("cities", out var cs) && cs.ValueKind == JsonValueKind.Array)
            g.Cities = cs.EnumerateArray()
                .Where(e => e.ValueKind == JsonValueKind.String)
                .Select(e => e.GetString() ?? "").ToList();
        if (root.TryGetProperty("bills", out var bs) && bs.ValueKind == JsonValueKind.Array)
            g.Bills = bs.EnumerateArray()
                .Select(e => JsonSerializer.Deserialize<BillInfo>(e.GetRawText(), options)!)
                .ToList();
        return g;
    }

    public override void Write(Utf8JsonWriter writer, TripGroup g, JsonSerializerOptions options)
    {
        writer.WriteStartObject();
        writer.WriteString("uid", g.Uid);
        writer.WriteString("key", g.Key);
        writer.WriteString("first_mmdd", g.FirstMMDD);
        writer.WriteString("last_mmdd", g.LastMMDD);
        writer.WritePropertyName("cities");
        writer.WriteStartArray();
        foreach (var s in g.Cities) writer.WriteStringValue(s);
        writer.WriteEndArray();
        writer.WritePropertyName("bills");
        writer.WriteStartArray();
        foreach (var b in g.Bills) JsonSerializer.Serialize(writer, b, options);
        writer.WriteEndArray();
        writer.WriteEndObject();
    }
}
