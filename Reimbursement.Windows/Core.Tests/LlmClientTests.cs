using System.Net;
using System.Text;
using System.Text.Json;
using Reimbursement.Core.Llm;
using Reimbursement.Core.Models;
using Xunit;

namespace Reimbursement.Core.Tests;

/// <summary>
/// LLM 客户端/识别编排测试：用假 HttpMessageHandler 模拟 OpenAI 兼容服务，
/// 覆盖两段式识别、400 回退、未配置兜底等编排行为（Swift 版无此覆盖，为新增）。
/// </summary>
public class LlmClientTests
{
    private sealed class FakeHandler : HttpMessageHandler
    {
        private readonly Queue<(HttpStatusCode Code, string Body)> _responses = new();
        public List<string> RequestBodies { get; } = new();
        public List<string> RequestUris { get; } = new();

        public void Enqueue(HttpStatusCode code, string body) => _responses.Enqueue((code, body));

        public static string Chat(string content) =>
            new JsonObject_ { Content = content }.ToJson();

        private sealed class JsonObject_
        {
            public required string Content { get; init; }
            public string ToJson()
            {
                var esc = JsonSerializer.Serialize(Content);
                return "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":" + esc + "}}]}";
            }
        }

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request, CancellationToken cancellationToken)
        {
            RequestUris.Add(request.RequestUri!.ToString());
            RequestBodies.Add(request.Content == null
                ? "" : await request.Content.ReadAsStringAsync(cancellationToken));
            var (code, body) = _responses.Count > 0
                ? _responses.Dequeue()
                : (HttpStatusCode.InternalServerError, "no more fake responses");
            return new HttpResponseMessage(code)
            {
                Content = new StringContent(body, Encoding.UTF8, "application/json"),
            };
        }
    }

    private static (LlmRecognizer Rec, FakeHandler Handler) MakeRecognizer(string apiKey = "sk-test")
    {
        var handler = new FakeHandler();
        var client = new LlmClient(
            new LlmConfig(apiKey, "https://api.example.com/v1", "test-model"),
            new HttpClient(handler));
        return (new LlmRecognizer(client), handler);
    }

    private static string SystemOf(string requestBody)
    {
        using var doc = JsonDocument.Parse(requestBody);
        return doc.RootElement.GetProperty("messages")[0].GetProperty("content").GetString()!;
    }

    /// <summary>两段式：分类命中 dining（0.9）→ 按 dining 抽取 → Receipt 字段正确。</summary>
    [Fact]
    public async Task TwoStageClassifyThenExtract()
    {
        var (rec, handler) = MakeRecognizer();
        handler.Enqueue(HttpStatusCode.OK, FakeHandler.Chat("""{"receipt_type":"dining","confidence":0.9}"""));
        handler.Enqueue(HttpStatusCode.OK, FakeHandler.Chat(
            """{"receipt_type":"dining","confidence":0.95,"fields":{"amount":580,"issue_date":"2026-09-16"},"error":""}"""));

        var r = await rec.RecognizeAsync("某某餐厅 消费 580 元", sourceFile: "a.pdf");

        Assert.Equal(BillType.Dining, r.ReceiptType);
        Assert.Equal("580", r.Field("amount"));
        Assert.Equal("2026-09-16", r.Field("issue_date"));
        Assert.Equal("a.pdf", r.SourceFile);
        Assert.Equal(2, handler.RequestBodies.Count);
        Assert.Contains("票据分类专家", SystemOf(handler.RequestBodies[0]));
        Assert.Contains("本次只处理「餐饮」", SystemOf(handler.RequestBodies[1]));
        Assert.All(handler.RequestUris, u => Assert.EndsWith("/chat/completions", u));
    }

    /// <summary>分类低置信（0.5 &lt; 0.7）→ 回退单段全量 prompt。</summary>
    [Fact]
    public async Task ClassifyLowConfidenceFallsBackToFullPrompt()
    {
        var (rec, handler) = MakeRecognizer();
        handler.Enqueue(HttpStatusCode.OK, FakeHandler.Chat("""{"receipt_type":"hotel_folio","confidence":0.5}"""));
        handler.Enqueue(HttpStatusCode.OK, FakeHandler.Chat(
            """{"receipt_type":"hotel_folio","confidence":0.9,"fields":{"hotel_name":"厦门某酒店","check_in_date":"2026-09-10","check_out_date":"2026-09-12","city":"厦门","amount":1200},"error":""}"""));

        var r = await rec.RecognizeAsync("厦门某酒店 入住 2026-09-10 离店 2026-09-12 1200");

        Assert.Equal(BillType.HotelFolio, r.ReceiptType);
        Assert.Equal(2, handler.RequestBodies.Count);
        Assert.Contains("专业的中国票据识别专家", SystemOf(handler.RequestBodies[1]));
    }

    /// <summary>带 response_format 收到 400 → 去掉后重试；system 的 JSON 提示只在带格式那次追加。</summary>
    [Fact]
    public async Task ChatJsonFormat400RetriesWithoutFormat()
    {
        var handler = new FakeHandler();
        var client = new LlmClient(new LlmConfig("sk-test", "https://api.example.com/v1", "m"),
            new HttpClient(handler));
        handler.Enqueue(HttpStatusCode.BadRequest, "response_format unsupported");
        handler.Enqueue(HttpStatusCode.OK, FakeHandler.Chat("hello"));

        var content = await client.ChatAsync("你好", "讲个笑话");

        Assert.Equal("hello", content);
        Assert.Equal(2, handler.RequestBodies.Count);
        Assert.Contains("response_format", handler.RequestBodies[0]);
        Assert.DoesNotContain("response_format", handler.RequestBodies[1]);
        Assert.Contains("请以合法 JSON 输出你的响应", SystemOf(handler.RequestBodies[0]));
        Assert.Equal("你好", SystemOf(handler.RequestBodies[1]));
    }

    /// <summary>未配置 API Key：识别器不抛错，返回 other + error 说明（且不发任何请求）。</summary>
    [Fact]
    public async Task NoApiKeyReturnsErrorReceipt()
    {
        var (rec, handler) = MakeRecognizer(apiKey: "");
        var r = await rec.RecognizeAsync("任意文本");
        Assert.Equal(BillType.Other, r.ReceiptType);
        Assert.Equal("未配置 LLM API Key", r.Error);
        Assert.Empty(handler.RequestBodies);
    }

    /// <summary>空 OCR 文本且无文件名 → 直接兜底，不调 LLM。</summary>
    [Fact]
    public async Task EmptyOcrReturnsErrorReceipt()
    {
        var (rec, handler) = MakeRecognizer();
        var r = await rec.RecognizeAsync("   ");
        Assert.Equal("OCR 文本为空且无文件名", r.Error);
        Assert.Empty(handler.RequestBodies);
    }

    /// <summary>ListModels 解析 data[].id。</summary>
    [Fact]
    public async Task ListModelsParsesIds()
    {
        var handler = new FakeHandler();
        var client = new LlmClient(new LlmConfig("sk-test", "https://api.example.com/v1", "m"),
            new HttpClient(handler));
        handler.Enqueue(HttpStatusCode.OK, """{"data":[{"id":"gpt-a"},{"id":"gpt-b"}]}""");
        var models = await client.ListModelsAsync();
        Assert.Equal(new[] { "gpt-a", "gpt-b" }, models);
    }
}

/// <summary>.env 解析/存盘（Swift 版无测试，为新增覆盖）。</summary>
public class LlmSettingsStoreTests
{
    [Fact]
    public void ParseEnvQuirks()
    {
        var text = """
            # 注释行
            LLM_API_KEY=sk-123
            export LLM_MODEL="deepseek-chat"
            LLM_BASE_URL='https://api.deepseek.com/v1'
            LLM_TIMEOUT=90 # 行尾注释
            EMPTY_LINE_ABOVE=yes

            """;
        var pairs = LlmSettingsStore.ParseEnv(text).ToDictionary(p => p.Key, p => p.Value);
        Assert.Equal("sk-123", pairs["LLM_API_KEY"]);
        Assert.Equal("deepseek-chat", pairs["LLM_MODEL"]);
        Assert.Equal("https://api.deepseek.com/v1", pairs["LLM_BASE_URL"]);
        Assert.Equal("90", pairs["LLM_TIMEOUT"]);
        Assert.Equal("yes", pairs["EMPTY_LINE_ABOVE"]);
    }

    [Fact]
    public void SaveLoadRoundTrip()
    {
        var dir = Path.Combine(Path.GetTempPath(), "reimburse-test-" + Guid.NewGuid().ToString("N"));
        var envPath = Path.Combine(dir, ".env");
        try
        {
            var store = new LlmSettingsStore(envPath);
            store.Settings.ApiKey = "sk-x";
            store.Settings.BaseUrl = "https://api.deepseek.com/v1";
            store.Settings.Model = "deepseek-chat";
            store.Settings.TimeoutSeconds = 90;
            store.Settings.BuyerName = "医科达（上海）医疗器械有限公司";
            store.Settings.BuyerTaxNo = "91310000XXXXXXXXXX";
            store.Settings.ExcludeCities = new List<string> { "重庆", "成都" };
            store.Save();

            var text = File.ReadAllText(envPath);
            Assert.Contains("EXCLUDE_CITIES=重庆,成都", text);
            Assert.Contains("LLM_TIMEOUT=90", text);

            var loaded = new LlmSettingsStore(envPath).Settings;
            Assert.Equal("sk-x", loaded.ApiKey);
            Assert.Equal("deepseek-chat", loaded.Model);
            Assert.Equal(90, loaded.TimeoutSeconds);
            Assert.Equal("医科达（上海）医疗器械有限公司", loaded.BuyerName);
            Assert.Equal(new[] { "重庆", "成都" }, loaded.ExcludeCities);
            Assert.True(loaded.HomeCities.SetEquals(new[] { "重庆", "成都" }));
        }
        finally
        {
            if (Directory.Exists(dir)) Directory.Delete(dir, recursive: true);
        }
    }
}
