using PDFtoImage;
using Reimbursement.Core.Recognition;
using SkiaSharp;

namespace Reimbursement.Ocr;

/// <summary>
/// PDF 页面渲染器：PDFtoImage（PDFium + SkiaSharp），逐页懒渲染 PNG 喂 PaddleOCR（评估 M1）。
/// 逐页渲染 + 逐页编码，内存峰值只与单页有关；超大页面自动降 DPI，
/// 把长边压到 4096px 以内（PaddleOCR 检测器内部还会再缩放，300DPI 以上纯属白烧 CPU）。
/// PDFium 非线程安全：进程内锁串行化全部渲染调用（锁在枚举期间持有）。
/// </summary>
public sealed class PdfToImageRenderer : IPdfPageRenderer
{
    private static readonly object Gate = new();
    private const int MaxLongEdge = 4096;

    public IEnumerable<byte[]> EnumeratePngPages(string pdfPath, int dpi = 300)
    {
        var bytes = File.ReadAllBytes(pdfPath);
        lock (Gate)
        {
            var count = Conversion.GetPageCount(bytes, (string?)null);
            for (var page = 0; page < count; page++)
            {
                yield return RenderPage(bytes, page, dpi);
            }
        }
    }

    private static byte[] RenderPage(byte[] bytes, int page, int dpi)
    {
        var effectiveDpi = dpi;
        while (true)
        {
            using var bitmap = Conversion.ToImage(bytes, page, (string?)null,
                new RenderOptions { Dpi = effectiveDpi });
            var longEdge = Math.Max(bitmap.Width, bitmap.Height);
            if (longEdge <= MaxLongEdge || effectiveDpi <= 100)
            {
                using var data = bitmap.Encode(SKEncodedImageFormat.Png, 100);
                return data?.ToArray() ?? Array.Empty<byte>();
            }
            // 按比例降档后重渲染这一页（只影响超大页面，如整册扫描合同）
            effectiveDpi = Math.Max(100, (int)(effectiveDpi * (double)MaxLongEdge / longEdge));
        }
    }
}
