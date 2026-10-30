namespace Reimbursement.Core.Recognition;

/// <summary>文档文本的来源。</summary>
public enum DocumentTextSource
{
    None,
    PdfTextLayer,
    LocalOcr,
    Oxr,
}

/// <summary>统一的文档文本提取结果。失败时 Text 为已获得的部分文本（可能为空），Message 说明原因。</summary>
public sealed record DocumentTextResult(
string Text,
DocumentTextSource Source,
string Message = "",
int PageCount = 0)
{
    public bool HasUsableText => !TextExtractor.LooksScanned(Text);
}

/// <summary>OCR 引擎输出的一块文本及其在页面中的位置（坐标为像素）。</summary>
public sealed record OcrBlock(
string Text,
double CenterX,
double CenterY,
double Width,
double Height,
double Score = 0);

/// <summary>把 OCR 文本块按阅读顺序（先行后列）拼成纯文本，供 LLM 抽取。</summary>
public static class OcrTextFormatter
{
    public static string Format(IEnumerable<OcrBlock> blocks)
    {
        var sorted = blocks
        .Where(b => !string.IsNullOrWhiteSpace(b.Text))
        .Select(b => b with { Text = b.Text.Trim() })
        .OrderBy(b => b.CenterY)
        .ThenBy(b => b.CenterX)
        .ToList();
        if (sorted.Count == 0) return "";

        var lines = new List<List<OcrBlock>>();
        foreach (var block in sorted)
        {
            var line = lines.LastOrDefault();
            if (line == null || !SameLine(line, block))
            {
                lines.Add(new List<OcrBlock> { block });
            }
            else
            {
                line.Add(block);
            }
        }

        return string.Join("\n", lines.Select(line =>
        JoinFragments(line.OrderBy(b => b.CenterX).Select(b => b.Text))));
    }

    private static bool SameLine(List<OcrBlock> line, OcrBlock block)
    {
        var avgY = line.Average(b => b.CenterY);
        var avgH = line.Average(b => b.Height);
        var tolerance = Math.Max(8, Math.Max(avgH, block.Height) * 0.55);
        return Math.Abs(block.CenterY - avgY) <= tolerance;
    }

    private static string JoinFragments(IEnumerable<string> fragments)
    {
        var result = "";
        foreach (var f in fragments)
        {
            if (result.Length == 0) { result = f; continue; }
            // 中文片段之间不加空格，英文/数字片段之间保留一个空格。
            var needSpace = !"，。、；：？！）】》".Contains(f[0]) && !(IsCjk(result[^1]) && IsCjk(f[0]));
            result += (needSpace ? " " : "") + f;
        }
        return result;
    }

    private static bool IsCjk(char c) =>
    (c >= 0x4E00 && c <= 0x9FFF) || (c >= 0x3400 && c <= 0x4DBF) ||
    (c >= 0xF900 && c <= 0xFAFF) || "，。、；：？！（）《》“”‘’".Contains(c);
}

/// <summary>图片 OCR 引擎（输入图片字节，输出带坐标的文本块）。实现必须可被多次调用。</summary>
public interface IImageOcrEngine
{
    string DisplayName { get; }
    Task<IReadOnlyList<OcrBlock>> RecognizeBlocksAsync(byte[] imageBytes, CancellationToken ct = default);
}

/// <summary>把 PDF 逐页渲染为 PNG 字节（OCR 前置步骤）。</summary>
public interface IPdfPageRenderer
{
    /// <summary>
    /// 逐页懒渲染 PNG（评估 M1）：调用方逐页消费、逐页释放，
    /// 不再整册物化（100 页扫描件旧契约可吃掉 0.5–2.5GB 内存）。
    /// </summary>
    IEnumerable<byte[]> EnumeratePngPages(string pdfPath, int dpi = 300);
}

/// <summary>文档 → 纯文本的统一入口（文本层 / OCR / 外部解析）。</summary>
public interface IDocumentTextProvider
{
    Task<DocumentTextResult> ExtractAsync(string path, CancellationToken ct = default);
}

/// <summary>
/// 默认文档文本管线：
/// PDF 先直提文本层；不足时优先按配置走外部解析（OXR），失败再回退本地 OCR（渲染 + 图片 OCR）；
/// 图片文件直接走外部解析或本地 OCR。
/// </summary>
public sealed class DocumentTextExtractor : IDocumentTextProvider
{
    private static readonly HashSet<string> ImageExtensions = new(StringComparer.OrdinalIgnoreCase)
{ ".jpg", ".jpeg", ".png", ".bmp", ".webp", ".tif", ".tiff"};

    private readonly IImageOcrEngine? _localOcr;
    private readonly IPdfPageRenderer? _renderer;
    private readonly IDocumentTextProvider? _externalParser;
    private readonly bool _preferExternal;
    private readonly int _renderDpi;

    public DocumentTextExtractor(
    IImageOcrEngine? localOcr = null,
    IPdfPageRenderer? renderer = null,
    IDocumentTextProvider? externalParser = null,
    bool preferExternal = false,
    int renderDpi = 300)
    {
        _localOcr = localOcr;
        _renderer = renderer;
        _externalParser = externalParser;
        _preferExternal = preferExternal;
        _renderDpi = renderDpi;
    }

    public async Task<DocumentTextResult> ExtractAsync(string path, CancellationToken ct = default)
    {
        if (!File.Exists(path))
            return new DocumentTextResult("", DocumentTextSource.None, "文件不存在");
        var ext = Path.GetExtension(path);
        var isPdf = string.Equals(ext, ".pdf", StringComparison.OrdinalIgnoreCase);
        var isImage = ImageExtensions.Contains(ext);
        if (!isPdf && !isImage)
            return new DocumentTextResult("", DocumentTextSource.None, $"不支持的文件类型：{ext}");

        if (isPdf)
        {
            var layer = TextExtractor.Extract(path);
            if (!TextExtractor.LooksScanned(layer))
                return new DocumentTextResult(layer, DocumentTextSource.PdfTextLayer);
        }

        // 外部解析优先（用户在设置里选了 OXR 时）
        string externalNote = "";
        if (_preferExternal && _externalParser != null)
        {
            var external = await _externalParser.ExtractAsync(path, ct);
            if (external.HasUsableText) return external;
            externalNote = external.Message.Length > 0 ? $"OXR：{external.Message}；" : "";
        }

        if (_localOcr == null)
        {
            return new DocumentTextResult("", DocumentTextSource.None,
            externalNote + (isPdf
            ? "无文本层（疑似扫描件），本地 OCR 引擎不可用"
            : "图片票据需要 OCR，但本地 OCR 引擎不可用"));
        }

        try
        {
            if (isImage)
            {
                var blocks = await _localOcr.RecognizeBlocksAsync(await File.ReadAllBytesAsync(path, ct), ct);
                var text = OcrTextFormatter.Format(blocks);
                return TextExtractor.LooksScanned(text)
                ? new DocumentTextResult(text, DocumentTextSource.None,
                externalNote + $"{_localOcr.DisplayName} 未识别出可用文本", 1)
                : new DocumentTextResult(text, DocumentTextSource.LocalOcr, "", 1);
            }

            if (_renderer == null)
            {
                return new DocumentTextResult("", DocumentTextSource.None,
                externalNote + "缺少 PDF 页面渲染器，无法对扫描件做 OCR");
            }

            // 逐页流式：渲染一页 → OCR 一页 → 释放，内存峰值只与单页有关（评估 M1）
            var parts = new List<string>();
            var pageCount = 0;
            using var en = _renderer.EnumeratePngPages(path, _renderDpi).GetEnumerator();
            while (true)
            {
                ct.ThrowIfCancellationRequested();
                if (!await Task.Run(() => en.MoveNext(), ct)) break;
                pageCount++;
                var blocks = await _localOcr.RecognizeBlocksAsync(en.Current, ct);
                var pageText = OcrTextFormatter.Format(blocks);
                if (pageText.Length > 0) parts.Add(pageText);
            }
            var all = string.Join("\n", parts);
            return TextExtractor.LooksScanned(all)
            ? new DocumentTextResult(all, DocumentTextSource.None,
            externalNote + $"{_localOcr.DisplayName} 未识别出可用文本", pageCount)
            : new DocumentTextResult(all, DocumentTextSource.LocalOcr, "", pageCount);
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception ex)
        {
            return new DocumentTextResult("", DocumentTextSource.None,
            externalNote + $"OCR 失败：{ex.Message}");
        }
    }
}
