using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Reimbursement.Core.Models;

/// <summary>Session 全量清单（对应 Swift SessionManifest），落盘为 sessions/{sid}/manifest.json。</summary>
public sealed class SessionManifest
{
    /// <summary>清单结构版本（评估 M3）：1 起步；旧文件无此字段按 0 处理，加载时迁移。</summary>
    [JsonPropertyName("schema_version")] public int SchemaVersion { get; set; }
    [JsonPropertyName("sid")] public string Sid { get; set; } = "";
    [JsonPropertyName("created_at")] public string CreatedAt { get; set; } = "";
    [JsonPropertyName("ocr_available")] public bool OcrAvailable { get; set; }
    [JsonPropertyName("llm_available")] public bool LlmAvailable { get; set; }
    [JsonPropertyName("bills")] public List<BillInfo> Bills { get; set; } = new();
    [JsonPropertyName("trips")] public List<TripGroup> Trips { get; set; } = new();
    [JsonPropertyName("local")] public List<BillInfo> Local { get; set; } = new();
    [JsonPropertyName("needs_review_count")] public int NeedsReviewCount { get; set; }

    /// <summary>
    /// 单一事实源标记（评估 S2）：Bills 是唯一权威清单；Trips/Local 是 Finalize 时的派生视图。
    /// Finalized=true 时加载会用 Bills + HomeCities 重新派生 Trips/Local（不信任盘上副本），
    /// 保证删除/替换后三处永不分叉、已删票据不会在导出里复活。
    /// </summary>
    [JsonPropertyName("finalized")] public bool Finalized { get; set; }
    [JsonPropertyName("home_cities")] public List<string> HomeCities { get; set; } = new();

    /// <summary>当前清单结构版本（写入用）。</summary>
    public const int CurrentSchemaVersion = 1;

    public SessionManifest() { }

    public SessionManifest(string sid, string createdAt, bool ocrAvailable, bool llmAvailable)
    {
        Sid = sid;
        CreatedAt = createdAt;
        OcrAvailable = ocrAvailable;
        LlmAvailable = llmAvailable;
    }
}

/// <summary>全仓统一的 JSON 选项：中文不转义、缩进输出（对应 Swift JSONEncoder 的 prettyPrinted）。</summary>
public static class ReimburseJson
{
    public static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };
}
