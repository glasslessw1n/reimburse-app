using PdfSharp.Pdf;
using PdfPigDocument = UglyToad.PdfPig.PdfDocument;
using PigRect = UglyToad.PdfPig.Core.PdfRectangle;

namespace Reimbursement.Core.Packaging;

/// <summary>
/// 一页的页面框（原始 PDF 坐标，左下原点）：MediaBox 与 CropBox。
/// 由调用方从 PDFsharp（与贴页绘制同一引擎）读出，保证坐标系同源。
/// </summary>
internal readonly record struct PdfPageBoxes(
    double MediaX, double MediaY, double MediaW, double MediaH,
    double CropX, double CropY, double CropW, double CropH)
{
    /// <summary>从 PDFsharp 页面读框：CropBox 缺失/异常时退化为 MediaBox。</summary>
    public static PdfPageBoxes FromPage(PdfPage page)
    {
        var m = page.MediaBox;
        double mx = m.X1, my = m.Y1, mw = m.X2 - m.X1, mh = m.Y2 - m.Y1;
        double cx = mx, cy = my, cw = mw, ch = mh;
        try
        {
            var c = page.CropBox;
            var w = c.X2 - c.X1;
            var h = c.Y2 - c.Y1;
            if (w > 0 && h > 0) { cx = c.X1; cy = c.Y1; cw = w; ch = h; }
        }
        catch (Exception)
        {
            // CropBox 读取失败：按与 MediaBox 相同处理（走整页/内容并集逻辑）
        }
        return new PdfPageBoxes(mx, my, mw, mh, cx, cy, cw, ch);
    }
}

/// <summary>
/// 计算 PDF 每页的"内容边框"，返回 PDFsharp 左上原点坐标（与 XPdfForm 绘制同空间）；
/// 无法确定时对应页返回 null，调用方回退整页 fit。
///
/// 用途：滴滴/餐饮类电子发票的源 PDF 常用 A4 竖版承载、发票本体只占一部分，
/// 整合排版旋转贴页时按整页 fit 会被空白拖小；按内容边框 fit 才能占满单元格。
///
/// 坐标纪律（2026-10-30 空白页事故的教训）：绝不跨引擎拼坐标。历史实现把 PdfPig 的
/// 裁剪框相对坐标当作 MediaBox 坐标用——普通发票（CropBox=MediaBox）下两系重合看不出，
/// 真实滴滴发票 CropBox=[0,432.9,610,864]≠MediaBox=[0,0,595.3,841.9] 时，
/// 算出的"内容框"落在页面下半的空白带上，贴页后整格空白。因此：
/// 1. 可见框（CropBox ∩ MediaBox）明显小于 MediaBox 时，内容框就是可见框本身——
///    框由 PDFsharp 同引擎读出，生成器声明的可见带即发票本体，无需第二引擎参与；
/// 2. CropBox 与 MediaBox 重合时，PdfPig 坐标与页面坐标同源，才用文字/图片/路径并集收紧；
/// 3. 其余异常框形一律返回 null 走整页 fit——发票小是难看，空白页是事故。
/// 任何解析失败都返回全 null，不影响排版主流程。
/// </summary>
internal static class PageContentBox
{
    public static List<(double X, double Y, double W, double H)?> Compute(
        string path, IReadOnlyList<bool> allowPerPage,
        IReadOnlyList<(double W, double H)> visualDims,
        IReadOnlyList<PdfPageBoxes> boxes)
    {
        var result = new List<(double X, double Y, double W, double H)?>();
        for (var i = 0; i < visualDims.Count; i++) result.Add(null);

        var needPig = new List<int>();
        for (var i = 0; i < result.Count; i++)
        {
            if (i >= allowPerPage.Count || !allowPerPage[i]) continue;
            if (i >= boxes.Count) continue;
            var g = boxes[i];
            var (pageW, pageH) = visualDims[i];
            if (g.MediaW <= 0 || g.MediaH <= 0) continue;

            // 可见框 V = CropBox ∩ MediaBox（原始左下原点坐标）
            var vx = Math.Max(g.MediaX, g.CropX);
            var vy = Math.Max(g.MediaY, g.CropY);
            var vx2 = Math.Min(g.MediaX + g.MediaW, g.CropX + g.CropW);
            var vy2 = Math.Min(g.MediaY + g.MediaH, g.CropY + g.CropH);
            var vw = vx2 - vx;
            var vh = vy2 - vy;
            if (vw < 40 || vh < 40) continue;

            var mediaArea = g.MediaW * g.MediaH;
            if (vw * vh < 0.92 * mediaArea)
            {
                // 分支 1：可见带页面（滴滴原发票）——内容框 = 可见框，换算到左上原点
                var box = (X: vx - g.MediaX, Y: (g.MediaY + g.MediaH) - vy2, W: vw, H: vh);
                if (IsSane(box, pageW, pageH)) result[i] = box;
                continue;
            }

            // 分支 2 的前置条件：CropBox 与 MediaBox 重合（PdfPig 坐标同源）
            var sameBox = Math.Abs(g.CropX - g.MediaX) <= 1 && Math.Abs(g.CropY - g.MediaY) <= 1
                          && Math.Abs(g.CropW - g.MediaW) <= 1 && Math.Abs(g.CropH - g.MediaH) <= 1;
            if (sameBox) needPig.Add(i);
            // 分支 3：框形异常但可见框几乎占满——不裁，整页 fit
        }

        if (needPig.Count == 0) return result;

        try
        {
            using var doc = PdfPigDocument.Open(path);
            var pages = doc.GetPages().ToList();
            foreach (var i in needPig)
            {
                if (i >= pages.Count) continue;
                var page = pages[i];
                var (pageW, pageH) = visualDims[i];

                double x0 = double.MaxValue, y0 = double.MaxValue;
                double x1 = double.MinValue, y1 = double.MinValue;
                void Union(PigRect r)
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

                var cw = x1 - x0;
                var ch = y1 - y0;
                // 合理性门槛：过小多半是解析噪声；几乎占满整页则无需裁剪
                if (cw < pageW * 0.3 || ch < pageH * 0.15) continue;
                if (cw * ch > pageW * pageH * 0.95) continue;

                // PDF 坐标（左下原点）→ PDFsharp（左上原点）；此分支两系同源
                var box = (X: x0, Y: pageH - y1, W: cw, H: ch);
                if (IsSane(box, pageW, pageH)) result[i] = box;
            }
        }
        catch (Exception)
        {
            // 解析失败：PdfPig 分支保持 null，整页 fit 兜底（可见带分支的结果不受影响）
        }
        return result;
    }

    /// <summary>内容框健全性：必须落在页面内（±1pt 容差）、尺寸与面积占比合理。</summary>
    private static bool IsSane((double X, double Y, double W, double H) b, double pageW, double pageH)
    {
        if (b.W < 30 || b.H < 30) return false;
        if (b.X < -1 || b.Y < -1) return false;
        if (b.X + b.W > pageW + 1 || b.Y + b.H > pageH + 1) return false;
        var ratio = b.W * b.H / (pageW * pageH);
        return ratio is >= 0.04 and <= 0.97;
    }
}
