using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Reimbursement.Core.Models;

/// <summary>Session 全量清单（对应 Swift SessionManifest），落盘为 sessions/{sid}/manifest.json。</summary>
public sealed class SessionManifest
{
    [JsonPropertyName("sid")] public string Sid { get; set; } = "";
    [JsonPropertyName("created_at")] public string CreatedAt { get; set; } = "";
    [JsonPropertyName("ocr_available")] public bool OcrAvailable { get; set; }
    [JsonPropertyName("llm_available")] public bool LlmAvailable { get; set; }
    [JsonPropertyName("bills")] public List<BillInfo> Bills { get; set; } = new();
    [JsonPropertyName("trips")] public List<TripGroup> Trips { get; set; } = new();
    [JsonPropertyName("local")] public List<BillInfo> Local { get; set; } = new();
    [JsonPropertyName("needs_review_count")] public int NeedsReviewCount { get; set; }

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
