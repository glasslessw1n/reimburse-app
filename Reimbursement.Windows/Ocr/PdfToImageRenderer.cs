using PDFtoImage;
using Reimbursement.Core.Recognition;
using SkiaSharp;

namespace Reimbursement.Ocr;

/// <summary>
/// PDF 页面渲染器：PDFtoImage（PDFium + SkiaSharp），逐页渲染为 PNG 字节喂 PaddleOCR。
/// PDFium 非线程安全，PDFtoImage 内部已串行化；这里再加进程内锁保证与 OCR 管线顺序执行。
/// </summary>
public sealed class PdfToImageRenderer : IPdfPageRenderer
{
    private static readonly object Gate = new();

    public IReadOnlyList<byte[]> RenderPngPages(string pdfPath, int dpi = 300)
    {
        var bytes = File.ReadAllBytes(pdfPath);
        lock (Gate)
        {
            var pages = new List<byte[]>();
            var bitmaps = Conversion.ToImages(bytes, (string?)null, new RenderOptions { Dpi = dpi });
            foreach (var bitmap in bitmaps)
            {
                using (bitmap)
                using (var data = bitmap.Encode(SKEncodedImageFormat.Png, 100))
                {
                    if (data != null) pages.Add(data.ToArray());
                }
            }
            return pages;
        }
    }
}
