using System.Net;
using System.Text;
using System.Text.Json;
using Reimbursement.Core.Llm;
using Reimbursement.Core.Models;
using Reimbursement.Core.Recognition;
using Xunit;

namespace Reimbursement.Core.Tests;

/// <summary>
/// UX v2 新增覆盖：OCR 文本块排序、文档文本管线回退（扫描件/图片 → OCR）、
/// OXR 响应解析与请求格式、识别管线进度与汇总。
/// </summary>
public class OcrPipelineTests
{
    // MARK: OcrTextFormatter

    [Fact]
    public void FormatterSortsBlocksIntoReadingOrder()
    {
        var blocks = new[]
        {
            new OcrBlock("第二行", 100, 60, 80, 20),
            new OcrBlock("金额", 40, 20, 40, 20),
            new OcrBlock("580", 120, 21, 40, 20),
            new OcrBlock("第一行", 100, 20, 80, 20),
        };
        // y=20 一行内按 x 排序：金额(40) → 第一行(100) → 580(120)；中文片段不加空格，数字前加空格
        Assert.Equal("金额第一行 580\n第二行", OcrTextFormatter.Format(blocks));
    }

    [Fact]
    public void FormatterDropsBlankBlocks()
    {
        Assert.Equal("", OcrTextFormatter.Format(new[] { new OcrBlock("  ", 0, 0, 1, 1) }));
    }

    // MARK: DocumentTextExtractor 回退

    private sealed class FakeOcrEngine : IImageOcrEngine
    {
        public string DisplayName => "FakeOCR";
        public int Calls;
        public Task<IReadOnlyList<OcrBlock>> RecognizeBlocksAsync(byte[] imageBytes, CancellationToken ct = default)
        {
            Calls++;
            IReadOnlyList<OcrBlock> blocks = new[]
            {
                new OcrBlock("扫描件酒店水单 金额 678.91 元 这是足够长的识别文本", 100, 20, 300, 20),
            };
            return Task.FromResult(blocks);
        }
    }

    private sealed class FakeRenderer : IPdfPageRenderer
    {
        public IEnumerable<byte[]> EnumeratePngPages(string pdfPath, int dpi = 300)
        {
            yield return new byte[] { 1, 2, 3 };
        }
    }

    private static string TempFile(string name, byte[] bytes)
    {
        var dir = Path.Combine(Path.GetTempPath(), "reimburse-ocr-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        var path = Path.Combine(dir, name);
        File.WriteAllBytes(path, bytes);
        return path;
    }

    [Fact]
    public async Task ImageFileGoesToOcr()
    {
        var ocr = new FakeOcrEngine();
        var extractor = new DocumentTextExtractor(ocr, new FakeRenderer());
        var path = TempFile("scan.jpg", new byte[] { 9, 9 });
        var result = await extractor.ExtractAsync(path);
        Assert.True(result.HasUsableText);
        Assert.Equal(DocumentTextSource.LocalOcr, result.Source);
        Assert.Contains("678.91", result.Text);
        Assert.Equal(1, ocr.Calls);
    }

    [Fact]
    public async Task ScannedPdfFallsBackToRenderPlusOcr()
    {
        var ocr = new FakeOcrEngine();
        var extractor = new DocumentTextExtractor(ocr, new FakeRenderer());
        // 假 PDF：PdfPig 打不开 → 文本层为空 → 应走渲染 + OCR 回退
        var path = TempFile("scan.pdf", Encoding.ASCII.GetBytes("%PDF-1.4 fake"));
        var result = await extractor.ExtractAsync(path);
        Assert.True(result.HasUsableText);
        Assert.Equal(DocumentTextSource.LocalOcr, result.Source);
        Assert.Equal(1, result.PageCount);
    }

    [Fact]
    public async Task ScannedPdfWithoutOcrReportsReason()
    {
        var extractor = new DocumentTextExtractor();
        var path = TempFile("scan.pdf", Encoding.ASCII.GetBytes("%PDF-1.4 fake"));
        var result = await extractor.ExtractAsync(path);
        Assert.False(result.HasUsableText);
        Assert.Contains("OCR 引擎不可用", result.Message);
    }

    [Fact]
    public async Task UnsupportedExtensionRejected()
    {
        var extractor = new DocumentTextExtractor(new FakeOcrEngine(), new FakeRenderer());
        var path = TempFile("note.txt", Encoding.UTF8.GetBytes("hello"));
        var result = await extractor.ExtractAsync(path);
        Assert.False(result.HasUsableText);
        Assert.Contains("不支持的文件类型", result.Message);
    }

    // MARK: OXR

    [Fact]
    public void OxrMarkdownExtraction()
    {
        var json = """{"code":0,"data":{"result":{"outputs":{"markdown":"# 水单\n金额 678.91","json":{}}}}}""";
        Assert.Equal("# 水单\n金额 678.91", OxrDocumentParser.ExtractMarkdown(json));
        Assert.Null(OxrDocumentParser.ExtractMarkdown("not json"));
        Assert.Null(OxrDocumentParser.ExtractMarkdown("""{"data":{}}"""));
    }

    private sealed class OxrFakeHandler : HttpMessageHandler
    {
        public string LastBody = "";
        public string LastUri = "";
        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request, CancellationToken cancellationToken)
        {
            LastUri = request.RequestUri!.ToString();
            LastBody = request.Content == null ? "" : await request.Content.ReadAsStringAsync(cancellationToken);
            var body = """{"data":{"result":{"outputs":{"markdown":"OXR 文本 金额 100 元 足够长的内容"}}}}""";
            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(body, Encoding.UTF8, "application/json"),
            };
        }
    }

    [Fact]
    public async Task OxrParserPostsMultipartAndReadsMarkdown()
    {
        var handler = new OxrFakeHandler();
        var parser = new OxrDocumentParser(
            new OxrOptions("https://free-oxr.example/api/v1"), new HttpClient(handler));
        var path = TempFile("a.png", new byte[] { 1 });
        var result = await parser.ExtractAsync(path);
        Assert.True(result.HasUsableText);
        Assert.Equal(DocumentTextSource.Oxr, result.Source);
        Assert.EndsWith("/parse/sync", handler.LastUri);
        Assert.Contains("dummy", handler.LastBody);          // 未配 Key 自动 dummy
        Assert.Contains("output_formats", handler.LastBody);
        Assert.Contains("markdown", handler.LastBody);
    }

    // MARK: RecognitionPipeline

    private sealed class FixedTextProvider : IDocumentTextProvider
    {
        private readonly string _text;
        public FixedTextProvider(string text) => _text = text;
        public Task<DocumentTextResult> ExtractAsync(string path, CancellationToken ct = default) =>
            Task.FromResult(new DocumentTextResult(_text, DocumentTextSource.PdfTextLayer));
    }

    private sealed class PipelineFakeHandler : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request, CancellationToken cancellationToken)
        {
            // 分类低置信 → 全量抽取，一律返回 dining 结果
            var content = request.RequestMessageSnapshot().Contains("票据分类专家")
                ? """{"receipt_type":"other","confidence":0.1}"""
                : """{"receipt_type":"dining","confidence":0.95,"fields":{"amount":58,"issue_date":"2026-10-01"},"error":""}""";
            var esc = JsonSerializer.Serialize(content);
            var body = "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":" + esc + "}}]}";
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(body, Encoding.UTF8, "application/json"),
            });
        }
    }

    [Fact]
    public async Task PipelineReportsProgressAndSummary()
    {
        var handler = new PipelineFakeHandler();
        var client = new LlmClient(
            new LlmConfig("sk-test", "https://api.example.com/v1", "m"), new HttpClient(handler));
        var pipeline = new RecognitionPipeline(
            new FixedTextProvider("某某餐厅 消费 58 元 足够长的文本内容"), new LlmRecognizer(client));

        var ingested = new List<BillInfo>();
        var events = new List<RecognitionProgress>();
        var progress = new Progress<RecognitionProgress>(p => { lock (events) events.Add(p); });
        var summary = await pipeline.RunAsync(
            new[] { "a.pdf", "b.pdf" },
            name => Path.Combine(Path.GetTempPath(), name),
            ingested.Add,
            progress);

        Assert.Equal(2, summary.Total);
        Assert.Equal(2, summary.Succeeded);
        Assert.Equal(0, summary.Failed);
        Assert.Equal(2, ingested.Count);
        Assert.All(ingested, b => Assert.Equal(BillType.Dining, b.BillType));
        // Progress<T> 是异步投递，等待事件到齐
        Assert.True(SpinWait.SpinUntil(() => { lock (events) return events.Count >= 6; },
            TimeSpan.FromSeconds(5)));
        lock (events)
        {
            Assert.Contains(events, e => e.Stage == RecognitionStage.ExtractingText);
            Assert.Contains(events, e => e.Stage == RecognitionStage.Completed && e.Completed == 2);
        }
    }

    [Fact]
    public async Task PipelineExtractionFailureIngestsErrorBill()
    {
        var handler = new PipelineFakeHandler();
        var client = new LlmClient(
            new LlmConfig("sk-test", "https://api.example.com/v1", "m"), new HttpClient(handler));
        var pipeline = new RecognitionPipeline(
            new FixedTextProvider(""), new LlmRecognizer(client));
        var ingested = new List<BillInfo>();
        var summary = await pipeline.RunAsync(
            new[] { "scan.pdf" }, name => name, ingested.Add);
        Assert.Equal(1, summary.Failed);
        Assert.Single(ingested);
        Assert.NotEqual("", ingested[0].Error);
    }
}

internal static class HttpRequestMessageSnapshotExtensions
{
    public static string RequestMessageSnapshot(this HttpRequestMessage request)
    {
        // 同步读取请求体仅用于测试分流（内容为内存 JSON）。
        return request.Content == null
            ? "" : request.Content.ReadAsStringAsync().GetAwaiter().GetResult();
    }
}
