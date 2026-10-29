using System.Net.Http.Headers;
using System.Text.Json;

namespace Reimbursement.Core.Recognition;

/// <summary>OXR（SoMark 文档解析）配置。免费接口可不填 Key（客户端自动用 dummy）。</summary>
public sealed record OxrOptions(string BaseUrl, string ApiKey = "")
{
    public static readonly OxrOptions FreeDefault = new("https://free-oxr.somark.ai/api/v1");
}

/// <summary>
/// OXR 外部文档解析客户端（可选增强，不作内置默认）：
/// POST {BaseUrl}/parse/sync，multipart 字段 file / api_key / output_formats=markdown,json，
/// 取响应 data.result.outputs.markdown 作为文档文本。失败不抛异常，返回带原因的空结果，
/// 由 DocumentTextExtractor 决定是否回退本地 OCR。
/// </summary>
public sealed class OxrDocumentParser : IDocumentTextProvider
{
    private readonly OxrOptions _options;
    private readonly HttpClient _http;

    public OxrDocumentParser(OxrOptions options, HttpClient? http = null)
    {
        _options = options;
        _http = http ?? new HttpClient();
    }

    public async Task<DocumentTextResult> ExtractAsync(string path, CancellationToken ct = default)
    {
        if (!File.Exists(path))
            return new DocumentTextResult("", DocumentTextSource.None, "文件不存在");
        if (string.IsNullOrWhiteSpace(_options.BaseUrl))
            return new DocumentTextResult("", DocumentTextSource.None, "未配置 OXR 服务地址");

        try
        {
            using var form = new MultipartFormDataContent();
            var fileContent = new StreamContent(File.OpenRead(path));
            var ext = Path.GetExtension(path).ToLowerInvariant();
            fileContent.Headers.ContentType = new MediaTypeHeaderValue(ext switch
            {
                ".pdf" => "application/pdf",
                ".png" => "image/png",
                ".bmp" => "image/bmp",
                ".webp" => "image/webp",
                ".tif" or ".tiff" => "image/tiff",
                _ => "image/jpeg",
            });
            form.Add(fileContent, "file", Path.GetFileName(path));
            form.Add(new StringContent(string.IsNullOrWhiteSpace(_options.ApiKey) ? "dummy" : _options.ApiKey),
                "api_key");
            form.Add(new StringContent("markdown"), "output_formats");
            form.Add(new StringContent("json"), "output_formats");

            var url = _options.BaseUrl.TrimEnd('/') + "/parse/sync";
            using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            timeoutCts.CancelAfter(TimeSpan.FromSeconds(120));
            using var resp = await _http.PostAsync(url, form, timeoutCts.Token);
            var body = await resp.Content.ReadAsStringAsync(timeoutCts.Token);
            if (!resp.IsSuccessStatusCode)
            {
                return new DocumentTextResult("", DocumentTextSource.None,
                    $"OXR 服务返回 HTTP {(int)resp.StatusCode}：{(body.Length > 160 ? body[..160] : body)}");
            }

            var markdown = ExtractMarkdown(body);
            if (string.IsNullOrWhiteSpace(markdown))
            {
                return new DocumentTextResult("", DocumentTextSource.None,
                    "OXR 响应中没有 markdown 文本");
            }
            return new DocumentTextResult(markdown, DocumentTextSource.Oxr);
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception ex)
        {
            return new DocumentTextResult("", DocumentTextSource.None, $"OXR 调用失败：{ex.Message}");
        }
    }

    /// <summary>从 OXR 响应 JSON 中取 markdown（兼容 data.result.outputs / data.outputs / result 三种层级）。</summary>
    public static string? ExtractMarkdown(string responseJson)
    {
        try
        {
            using var doc = JsonDocument.Parse(responseJson);
            var root = doc.RootElement;
            foreach (var candidate in new[] { root, Prop(root, "data"), Prop(root, "result") })
            {
                if (candidate is not { } node) continue;
                var resultNode = Prop(node, "result") ?? node;
                if (Prop(resultNode, "outputs") is { } outputs &&
                    Prop(outputs, "markdown") is { ValueKind: JsonValueKind.String } md)
                    return md.GetString();
                if (Prop(resultNode, "markdown") is { ValueKind: JsonValueKind.String } direct)
                    return direct.GetString();
            }
            return null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static JsonElement? Prop(JsonElement element, string name) =>
        element.ValueKind == JsonValueKind.Object && element.TryGetProperty(name, out var v) ? v : null;
}
