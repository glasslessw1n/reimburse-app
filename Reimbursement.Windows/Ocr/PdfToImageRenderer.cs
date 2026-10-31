using PDFtoImage;
using Reimbursement.Core.Recognition;
using SkiaSharp;

namespace Reimbursement.Ocr;

/// <summary>
/// PDF 页面渲染器：PDFtoImage（PDFium + SkiaSharp），逐页懒渲染 PNG 喂 PaddleOCR（评估 M1）。
/// 逐页渲染 + 逐页编码，内存峰值只与单页有关；超大页面自动降 DPI，
/// 把长边压到 4096px 以内（PaddleOCR 检测器内部还会再缩放，300DPI 以上纯属白烧 CPU）。
/// PDFium 非线程安全：进程内信号量串行化全部渲染调用（枚举期间持有）。
/// ⚠️ 必须用 SemaphoreSlim 而不是 lock/Monitor：消费方（DocumentTextExtractor）在
/// Task.Run 里调 MoveNext、在 await 之间反复横跳线程，Monitor 有线程亲和性——
/// 枚举结束时 Exit 落在别的线程会抛 SynchronizationLockException 且锁永不释放，
/// 表现为"某张扫描件 OCR 失败 + 下一张起提取永久卡死"（v1.3.1 实测修复）。
/// </summary>
public sealed class PdfToImageRenderer : IPdfPageRenderer
{
    private static readonly SemaphoreSlim Gate = new(1, 1);
    private const int MaxLongEdge = 4096;

    public IEnumerable<byte[]> EnumeratePngPages(string pdfPath, int dpi = 300)
    {
        var bytes = File.ReadAllBytes(pdfPath);
        Gate.Wait();
        try
        {
            var count = Conversion.GetPageCount(bytes, (string?)null);
            for (var page = 0; page < count; page++)
            {
                yield return RenderPage(bytes, page, dpi);
            }
        }
        finally
        {
            Gate.Release();
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
