using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Reimbursement.Core.Llm;

/// <summary>LLM 配置（对应 Swift LLMConfig）。BaseUrl 形如 https://api.deepseek.com/v1（无尾斜杠亦可）。</summary>
public sealed record LlmConfig(string ApiKey, string BaseUrl, string Model, double TimeoutSeconds = 60)
{
    public static readonly LlmConfig Default = new("", "https://api.openai.com/v1", "gpt-4o-mini");
}

public sealed class LlmException : Exception
{
    public enum Kind { NotConfigured, Http, InvalidResponse, ParseFailed, AllRetriesFailed }

    public Kind ErrorKind { get; }
    public int HttpStatus { get; }

    private LlmException(Kind kind, string message, int status = 0) : base(message)
    {
        ErrorKind = kind;
        HttpStatus = status;
    }

    public static LlmException NotConfigured() => new(Kind.NotConfigured, "未配置 LLM API Key");
    public static LlmException Http(int code, string body) =>
        new(Kind.Http, $"HTTP {code}: {(body.Length > 200 ? body[..200] : body)}", code);
    public static LlmException InvalidResponse() => new(Kind.InvalidResponse, "响应格式无效");
    public static LlmException ParseFailed(string s) =>
        new(Kind.ParseFailed, $"JSON 解析失败：{(s.Length > 200 ? s[..200] : s)}");
    public static LlmException AllRetriesFailed(string s) => new(Kind.AllRetriesFailed, $"LLM 调用失败：{s}");
}

/// <summary>
/// OpenAI Chat Completions 兼容协议客户端（对应 Swift LLMClient / Python call_llm_json）。
/// 支持 OpenAI / DeepSeek / 月之暗面 / 智谱 / Ollama / vLLM 等任何兼容服务。
/// HttpClient 可注入（测试用假 handler、App 层配代理/超时）。
/// </summary>
public sealed class LlmClient
{
    private readonly LlmConfig _config;
    private readonly HttpClient _http;

    public LlmConfig Config => _config;

    public LlmClient(LlmConfig config, HttpClient? http = null)
    {
        _config = config;
        _http = http ?? new HttpClient();
    }

    private string Endpoint(string path) => _config.BaseUrl.TrimEnd('/') + "/" + path;

    /// <summary>
    /// 主入口：发 system + user → 拿 content string。
    /// useJSONFormat=true 且 system 不含 "json" 时自动追加提示（OpenAI json_object 模式的硬性要求）；
    /// 带 response_format 收到 400 时自动去掉重试一次。
    /// </summary>
    public async Task<string> ChatAsync(string system, string user,
        double temperature = 0.0, bool useJSONFormat = true, CancellationToken ct = default)
    {
        if (_config.ApiKey.Length == 0) throw LlmException.NotConfigured();

        var systemForJson = system;
        if (useJSONFormat && !system.Contains("json", StringComparison.OrdinalIgnoreCase))
            systemForJson += "\n\n请以合法 JSON 输出你的响应。";

        var maxAttempts = useJSONFormat ? 2 : 1;
        LlmException? lastError = null;

        for (var attempt = 1; attempt <= maxAttempts; attempt++)
        {
            var useFormatThisTime = useJSONFormat && attempt == 1;

            var payload = new JsonObject
            {
                ["model"] = _config.Model,
                ["messages"] = new JsonArray
                {
                    new JsonObject { ["role"] = "system", ["content"] = useFormatThisTime ? systemForJson : system },
                    new JsonObject { ["role"] = "user", ["content"] = user },
                },
                ["temperature"] = temperature,
            };
            if (useFormatThisTime)
                payload["response_format"] = new JsonObject { ["type"] = "json_object" };

            using var req = new HttpRequestMessage(HttpMethod.Post, Endpoint("chat/completions"));
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _config.ApiKey);
            req.Content = new StringContent(payload.ToJsonString(), Encoding.UTF8, "application/json");

            using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            timeoutCts.CancelAfter(TimeSpan.FromSeconds(_config.TimeoutSeconds));

            using var resp = await _http.SendAsync(req, timeoutCts.Token);
            var bodyStr = await resp.Content.ReadAsStringAsync(timeoutCts.Token);

            if (resp.IsSuccessStatusCode)
            {
                try
                {
                    using var doc = JsonDocument.Parse(bodyStr);
                    var content = doc.RootElement
                        .GetProperty("choices")[0]
                        .GetProperty("message")
                        .GetProperty("content")
                        .GetString();
                    if (content == null) throw LlmException.InvalidResponse();
                    return content;
                }
                catch (LlmException) { throw; }
                catch (Exception)
                {
                    throw LlmException.ParseFailed(bodyStr);
                }
            }

            lastError = LlmException.Http((int)resp.StatusCode, bodyStr);
            if (useFormatThisTime && (int)resp.StatusCode == 400)
                continue; // JSON 模式被拒 → 不带 response_format 回退一次
            throw lastError;
        }

        throw lastError ?? LlmException.InvalidResponse();
    }

    /// <summary>
    /// 调 LLM 拿 JSON 对象（自动剥 markdown 代码块）。重试按错误类型分级（评估 H3）：
    /// 用户取消永不重试、直接上抛；HTTP 4xx（除 408/429）是永久错误不重试；
    /// 429/5xx/超时/网络错误才退避重试（1.5s×(n+1)），最多 maxRetries 次。
    /// </summary>
    public async Task<JsonElement> ChatJsonAsync(string system, string user,
        int maxRetries = 2, CancellationToken ct = default)
    {
        Exception? lastError = null;
        for (var attempt = 0; attempt <= maxRetries; attempt++)
        {
            try
            {
                var content = await ChatAsync(system, user, ct: ct);
                return JsonObjectExtractor.ExtractFirstJsonObject(content);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                throw; // 取消不被吞（旧版会被 catch-all 转入重试，点取消还要再挣扎一轮）
            }
            catch (Exception e)
            {
                if (!IsRetryable(e)) throw;
                lastError = e;
                if (attempt < maxRetries)
                    await Task.Delay(TimeSpan.FromSeconds(1.5 * (attempt + 1)), ct);
            }
        }
        throw LlmException.AllRetriesFailed(lastError?.Message ?? "unknown");
    }

    private static bool IsRetryable(Exception e) => e switch
    {
        LlmException { ErrorKind: LlmException.Kind.NotConfigured } => false,
        LlmException { ErrorKind: LlmException.Kind.Http, HttpStatus: var s } =>
            s == 408 || s == 429 || s >= 500,
        LlmException => true,               // 响应/解析类问题换一次调用可能恢复
        TaskCanceledException => true,      // 单次超时（非用户取消，已在上面拦截）
        HttpRequestException => true,
        _ => true,
    };

    /// <summary>拉模型列表（GET /models，超时 15s）。</summary>
    public async Task<List<string>> ListModelsAsync(CancellationToken ct = default)
    {
        using var req = new HttpRequestMessage(HttpMethod.Get, Endpoint("models"));
        req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _config.ApiKey);
        using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeoutCts.CancelAfter(TimeSpan.FromSeconds(15));

        using var resp = await _http.SendAsync(req, timeoutCts.Token);
        var body = await resp.Content.ReadAsStringAsync(timeoutCts.Token);
        if (!resp.IsSuccessStatusCode)
            throw LlmException.Http((int)resp.StatusCode, body);

        try
        {
            using var doc = JsonDocument.Parse(body);
            var models = new List<string>();
            if (doc.RootElement.TryGetProperty("data", out var arr) && arr.ValueKind == JsonValueKind.Array)
            {
                foreach (var item in arr.EnumerateArray())
                {
                    if (item.TryGetProperty("id", out var id) && id.ValueKind == JsonValueKind.String)
                        models.Add(id.GetString()!);
                }
            }
            return models;
        }
        catch (JsonException)
        {
            return new List<string>();
        }
    }
}
