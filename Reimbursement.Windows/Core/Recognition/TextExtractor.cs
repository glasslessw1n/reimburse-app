using UglyToad.PdfPig;

namespace Reimbursement.Core.Recognition;

/// <summary>
/// PDF 文本层提取（对应 mac 版 PdfTextExtractor 的定位）：电子发票/行程单多为带文本层的 PDF，
/// 文本直提后喂 LlmRecognizer 即可，无需 OCR。扫描件（无文本层）提取结果接近为空，
/// 由 App 层据此回退 OCR 引擎（见 OCR spike 分支）。
/// </summary>
public static class TextExtractor
{
    /// <summary>提取全部页面文本（逐页以换行拼接）。文件不存在或非 PDF 返回空串。</summary>
    public static string Extract(string path)
    {
        if (!File.Exists(path)) return "";
        if (!string.Equals(Path.GetExtension(path), ".pdf", StringComparison.OrdinalIgnoreCase))
            return "";
        try
        {
            using var doc = PdfDocument.Open(path);
            var parts = new List<string>();
            foreach (var page in doc.GetPages())
                parts.Add(page.Text);
            return string.Join("\n", parts);
        }
        catch
        {
            return "";
        }
    }

    /// <summary>粗略判断是否为扫描件：文本层字符数低于阈值视为无文本层。</summary>
    public static bool LooksScanned(string extractedText, int minChars = 20) =>
        extractedText.Trim().Length < minChars;
}
