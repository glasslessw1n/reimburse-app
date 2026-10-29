using UglyToad.PdfPig.Core;
using PdfPigDocument = UglyToad.PdfPig.PdfDocument;

namespace Reimbursement.Core.Packaging;

/// <summary>
/// 计算 PDF 每页的"内容边框"（文字 + 图片 + 矢量路径的包围盒并集），
/// 返回 PDFsharp 左上原点坐标；无法确定时对应页返回 null。
///
/// 用途：滴滴/餐饮类电子发票的源 PDF 常用 A4 竖版承载，发票本体只占上半页、
/// 下半页空白。整合排版旋转贴页时若按整页 fit，发票会被空白拖小、占不满单元格；
/// 按内容边框 fit 才能整板占版。内容几乎占满整页（如行程单）时返回 null 走整页 fit。
/// 任何解析失败都返回全 null，调用方回退整页 fit，不影响排版主流程。
/// </summary>
internal static class PageContentBox
{
    public static List<(double X, double Y, double W, double H)?> Compute(
        string path, IReadOnlyList<bool> allowPerPage,
        IReadOnlyList<(double W, double H)> visualDims)
    {
        var result = new List<(double X, double Y, double W, double H)?>();
        for (var i = 0; i < visualDims.Count; i++) result.Add(null);
        try
        {
            using var doc = PdfPigDocument.Open(path);
            var pages = doc.GetPages().ToList();
            for (var i = 0; i < Math.Min(pages.Count, result.Count); i++)
            {
                if (i >= allowPerPage.Count || !allowPerPage[i]) continue;
                var page = pages[i];

                double x0 = double.MaxValue, y0 = double.MaxValue;
                double x1 = double.MinValue, y1 = double.MinValue;
                void Union(PdfRectangle r)
                {
                    if (r.Left < x0) x0 = r.Left;
                    if (r.Bottom < y0) y0 = r.Bottom;
                    if (r.Right > x1) x1 = r.Right;
                    if (r.Top > y1) y1 = r.Top;
                }

                foreach (var letter in page.Letters) Union(letter.GlyphRectangle);
                foreach (var image in page.GetImages()) Union(image.Bounds);
                foreach (var p in page.Paths)
                {
                    // 剪切路径/未上漆路径不是可见内容（滴滴发票首条即整页剪切路径，
                    // 不排除会把内容边框撑回整页、裁剪永不触发）
                    if (p.IsClipping || (!p.IsFilled && !p.IsStroked)) continue;
                    if (p.GetBoundingRectangle() is { } r) Union(r);
                }
                if (x0 == double.MaxValue) continue;

                var (pageW, pageH) = visualDims[i];
                var cw = x1 - x0;
                var ch = y1 - y0;
                // 合理性门槛：过小多半是解析噪声；几乎占满整页则无需裁剪
                if (cw < pageW * 0.3 || ch < pageH * 0.15) continue;
                if (cw * ch > pageW * pageH * 0.95) continue;

                // PDF 坐标（左下原点）→ PDFsharp（左上原点）
                result[i] = (x0, pageH - y1, cw, ch);
            }
        }
        catch (Exception)
        {
            // 解析失败：保持全 null，整页 fit 兜底
        }
        return result;
    }
}
