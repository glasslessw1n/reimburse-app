using System.Globalization;
using System.Text.Json;
using Reimbursement.Core.Models;

namespace Reimbursement.Core.Llm;

/// <summary>
/// OCR 文本 → LLM → Receipt 的编排（对应 Swift LLMRecognizer / Python recognize）。
/// 两段式：先分类（短 prompt）→ 再按类型抽取（聚焦字段清单）；
/// 分类失败 / 低置信（&lt;0.7）/ other → 回退单段全量，保证不比单段差。
/// 失败兜底（不抛异常）：返回 receipt_type=other + confidence=0 + error 填原因。
/// </summary>
public sealed class LlmRecognizer
{
    private readonly LlmClient _client;

    public LlmRecognizer(LlmClient client) => _client = client;

    public async Task<Receipt> RecognizeAsync(string ocrText, string filename = "",
        string sourceFile = "", CancellationToken ct = default)
    {
        var recognizedAt = DateTimeOffset.Now.ToString("yyyy-MM-dd'T'HH:mm:sszzz", CultureInfo.InvariantCulture);
        var excerpt = ocrText.Length > 500 ? ocrText[..500] : ocrText;

        // 边界：LLM 没配
        if (_client.Config.ApiKey.Length == 0)
        {
            return new Receipt(BillType.Other, 0, new Dictionary<string, string?>(),
                excerpt, recognizedAt, sourceFile, "未配置 LLM API Key");
        }

        // 边界：OCR 文本完全空且没文件名
        if (ocrText.Trim().Length == 0 && filename.Length == 0)
        {
            return new Receipt(BillType.Other, 0, new Dictionary<string, string?>(),
                "", recognizedAt, sourceFile, "OCR 文本为空且无文件名");
        }

        var userMsg = LlmPrompts.BuildUserMessage(ocrText, filename);

        // 两段式：先分类，再按类型抽取；失败回退到单段全量
        var type = await ClassifyAsync(ocrText, filename, ct);
        if (type is { } t)
        {
            var receipt = await ExtractAsync(t, userMsg, excerpt, sourceFile, recognizedAt, ct);
            if (receipt != null) return receipt;
        }
        return await ExtractFullAsync(ocrText, userMsg, excerpt, sourceFile, recognizedAt, ct);
    }

    // MARK: - 第一段：分类

    /// <summary>返回确认的类型；失败 / 低置信 / other 返回 null（交给单段全量兜底）。</summary>
    private async Task<BillType?> ClassifyAsync(string ocrText, string filename, CancellationToken ct)
    {
        var userMsg = LlmPrompts.BuildUserMessage(ocrText, filename);
        try
        {
            var raw = await _client.ChatJsonAsync(LlmPrompts.ClassifySystemPrompt, userMsg, ct: ct);
            if (!raw.TryGetProperty("receipt_type", out var t) || t.ValueKind != JsonValueKind.String)
                return null;
            var type = BillTypeInfo.FromRaw(t.GetString());
            // 注意：Swift 版先用 BillType(rawValue:) 校验，未知枚举直接 nil；
            // FromRaw 把未知落 Other，下面的 type != Other 判断等效拦截。
            var confidence = DoubleValue(raw, "confidence");
            if (type == BillType.Other || confidence < 0.7) return null;
            return type;
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception)
        {
            return null;
        }
    }

    // MARK: - 第二段：按类型抽取

    private async Task<Receipt?> ExtractAsync(BillType type, string userMsg, string excerpt,
        string sourceFile, string recognizedAt, CancellationToken ct)
    {
        try
        {
            var raw = await _client.ChatJsonAsync(LlmPrompts.ExtractSystemPrompt(type), userMsg, ct: ct);
            return Decode(raw, excerpt, sourceFile, recognizedAt);
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception)
        {
            // 抽取失败 → 交给单段全量兜底
            return null;
        }
    }

    // MARK: - 单段全量（原行为，兜底）

    private async Task<Receipt> ExtractFullAsync(string ocrText, string userMsg, string excerpt,
        string sourceFile, string recognizedAt, CancellationToken ct)
    {
        JsonElement raw;
        try
        {
            raw = await _client.ChatJsonAsync(LlmPrompts.SystemPrompt, userMsg, ct: ct);
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception e)
        {
            // 诊断进 AppLog 文件（旧版写 stderr，WinExe 永远看不见——评估 S4）
            Diagnostics.AppLog.Error("llm",
                $"{sourceFile} LLM 调用失败 base={_client.Config.BaseUrl} model={_client.Config.Model}", e);
            return new Receipt(BillType.Other, 0, new Dictionary<string, string?>(),
                excerpt, recognizedAt, sourceFile, $"LLM 调用失败：{e.Message}");
        }
        return Decode(raw, excerpt, sourceFile, recognizedAt);
    }

    // MARK: - 解码

    private static Receipt Decode(JsonElement raw, string excerpt, string sourceFile, string recognizedAt)
    {
        try
        {
            var receipt = JsonSerializer.Deserialize<Receipt>(raw.GetRawText(), ReimburseJson.Options)
                          ?? throw new JsonException("空结果");
            receipt.RawTextExcerpt = excerpt;
            receipt.SourceFile = sourceFile;
            receipt.RecognizedAt = recognizedAt;
            return receipt;
        }
        catch (Exception e)
        {
            Diagnostics.AppLog.Error("llm", $"{sourceFile} Receipt 解析失败", e);
            return new Receipt(BillType.Other, 0, new Dictionary<string, string?>(),
                excerpt, recognizedAt, sourceFile, $"Receipt 解析失败：{e.Message}");
        }
    }

    /// <summary>JSON 数值 → double（容忍数字 / 字符串）。</summary>
    private static double DoubleValue(JsonElement obj, string key)
    {
        if (!obj.TryGetProperty(key, out var v)) return 0;
        if (v.ValueKind == JsonValueKind.Number) return v.GetDouble();
        if (v.ValueKind == JsonValueKind.String &&
            double.TryParse(v.GetString(), NumberStyles.Float, CultureInfo.InvariantCulture, out var d))
            return d;
        return 0;
    }
}
