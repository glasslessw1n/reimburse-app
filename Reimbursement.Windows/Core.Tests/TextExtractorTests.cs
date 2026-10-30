using System.Text;
using Reimbursement.Core.Recognition;
using Xunit;

namespace Reimbursement.Core.Tests;

/// <summary>
/// 文本层提取验证：手工组装一个带 Base-14 字体的最小 PDF（避免依赖字体解析器），
/// 断言 PdfPig 能提出文本；扫描件判据与异常路径返回空串。
/// </summary>
public class TextExtractorTests
{
    private static byte[] MakeTextPdf(string text)
    {
        var content = $"BT /F1 24 Tf 72 770 Td ({text}) Tj ET";
        var objects = new[]
        {
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] " +
                "/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            $"<< /Length {content.Length} >>\nstream\n{content}\nendstream",
        };
        var sb = new StringBuilder("%PDF-1.4\n");
        var offsets = new List<int>();
        for (var i = 0; i < objects.Length; i++)
        {
            offsets.Add(sb.Length);
            sb.Append($"{i + 1} 0 obj\n{objects[i]}\nendobj\n");
        }
        var xref = sb.Length;
        sb.Append($"xref\n0 {objects.Length + 1}\n0000000000 65535 f \n");
        foreach (var off in offsets)
            sb.Append($"{off:D10} 00000 n \n");
        sb.Append($"trailer\n<< /Size {objects.Length + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF");
        return Encoding.ASCII.GetBytes(sb.ToString());
    }

    [Fact]
    public void ExtractsTextLayer()
    {
        var dir = Directory.CreateDirectory(
            Path.Combine(Path.GetTempPath(), "reimburse-text-" + Guid.NewGuid().ToString("N")));
        try
        {
            var path = Path.Combine(dir.FullName, "t.pdf");
            File.WriteAllBytes(path, MakeTextPdf("REIMBURSE TEXT 12345"));
            var text = TextExtractor.Extract(path);
            Assert.Contains("REIMBURSE", text);
            Assert.Contains("12345", text);
            Assert.False(TextExtractor.LooksScanned(text));

            Assert.Equal("", TextExtractor.Extract(Path.Combine(dir.FullName, "missing.pdf")));
            Assert.True(TextExtractor.LooksScanned(""));
        }
        finally
        {
            Directory.Delete(dir.FullName, recursive: true);
        }
    }
}
