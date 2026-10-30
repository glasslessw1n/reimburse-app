using PdfSharp.Drawing;
using PdfSharp.Pdf;
using PdfSharp.Pdf.IO;
using Reimbursement.Core.Models;
using Reimbursement.Core.Storage;

namespace Reimbursement.Core.Packaging;

/// <summary>一条贴页记录（输出页号从 1 起；Rotation 为内容旋转角，-90 表示左旋 90°）。</summary>
public sealed record PlacedItem(int OutputPage, string SourceFile, int SourcePageIndex,
    string Rule, double X, double Y, double Width, double Height, int Rotation);

/// <summary>Compose 结果：总页数、逐条贴页清单、跳过项（文件名：原因）。</summary>
public sealed record ComposeResult(string OutputPath, int PageCount,
    IReadOnlyList<PlacedItem> Placements, IReadOnlyList<string> Skipped);

/// <summary>
/// 整合 PDF 排版引擎（对应 toolkit 的 compose.py，数据源从"文件名解析"换成会话识别记录）。
/// 排版规则与 toolkit 一致：A4、边距 20pt、间距 8pt；行程证明页 P1（去+回上下排）、
/// 交通 3×2、酒店水单整页、酒店发票同页上下两份、滴滴/餐饮/自驾票据左旋 90° 网格、自驾行程单整页。
/// 相对 toolkit 的三处缺陷修复（有意为之）：
/// 1. 多页文档逐页纳入（toolkit 只渲染第 0 页，多页会丢页）；
/// 2. 未出现在 P1 的登机牌进 3×2 网格（toolkit 里单张/中间登机牌会整张消失）；
/// 3. 行程内与本地的其他类票据（出租/通信/其他等）走 1×2 兜底排版（toolkit 直接丢弃）。
/// 实现方式也不同：toolkit 是 144dpi 光栅图贴页，这里是矢量贴页（XForm），文字保持清晰、体积更小；
/// 图片原件（jpg/png/bmp）按同样的 fit 规则贴图（与 toolkit 对图片的处理等效）。
/// 与 toolkit 的一处行为差异（用户实测后要求）：旋转贴页时若源页内容只占页面一部分
/// （滴滴发票是 A4 竖版承载、发票本体只占上半页），按内容边框裁剪后再 fit，
/// 否则发票会被整页空白拖小、占不满单元格；toolkit 按整页光栅 fit 同样偏小。
/// </summary>
public static class PdfComposer
{
    public const double A4W = 595.28;
    public const double A4H = 841.89;
    public const double Margin = 20.0;
    public const double Gap = 8.0;

    private static (double X, double Y, double W, double H) CellRect(int col, int row, int cols, int rows)
    {
        var cellW = (A4W - 2 * Margin - Gap * (cols - 1)) / cols;
        var cellH = (A4H - 2 * Margin - Gap * (rows - 1)) / rows;
        return (Margin + col * (cellW + Gap), Margin + row * (cellH + Gap), cellW, cellH);
    }

    private static readonly (double X, double Y, double W, double H) FullRect =
        (Margin, Margin, A4W - 2 * Margin, A4H - 2 * Margin);

    /// <summary>建议输出文件名：报销单整合_MMDD-MMDD.pdf（与 toolkit 的命名规则一致）。</summary>
    public static string SuggestFileName(SessionManager session)
    {
        var trips = session.Manifest.Trips;
        if (trips.Count == 0) return "报销单整合.pdf";
        return $"报销单整合_{trips[0].FirstMMDD}-{trips[^1].LastMMDD}.pdf";
    }

    /// <summary>按会话 manifest 的行程/本地分组生成整合 PDF。</summary>
    public static ComposeResult Compose(SessionManager session, string outputPath)
    {
        var originals = Path.Combine(session.RootDir, "originals");
        using var engine = new Engine(originals);
        foreach (var trip in session.Manifest.Trips)
            engine.ComposeContainer(trip.Bills, isLocal: false);
        if (session.Manifest.Local.Count > 0)
            engine.ComposeContainer(session.Manifest.Local, isLocal: true);
        return engine.Save(outputPath);
    }

    // ── 引擎 ─────────────────────────────────────────────────────────────

    private sealed class Engine : IDisposable
    {
        private readonly string _originals;
        private readonly PdfDocument _output = new();
        private readonly List<PlacedItem> _placements = new();
        private readonly List<string> _skipped = new();
        private readonly Dictionary<string, SourceDoc?> _docCache = new(StringComparer.OrdinalIgnoreCase);
        private PdfPage? _page;
        private XGraphics? _gfx;
        private int _pageIndex;

        public Engine(string originals) => _originals = originals;

        public void Dispose()
        {
            _gfx?.Dispose();
            _output.Dispose();
            foreach (var d in _docCache.Values) d?.Dispose();
        }

        // MARK: 源文档

        private sealed class SourceDoc : IDisposable
        {
            public PdfDocument? Pdf;
            public XPdfForm? Form;
            public XImage? Image;
            /// <summary>每页的视觉尺寸（已按页面 /Rotate 交换宽高）。</summary>
            public List<(double W, double H)> PdfPageDims = new();
            /// <summary>每页的页面框（MediaBox/CropBox，PDFsharp 同引擎读出）。</summary>
            public List<PdfPageBoxes> PageBoxes = new();
            /// <summary>每页的内容边框（左上原点）；null = 按整页 fit。仅 /Rotate=0 的页计算。</summary>
            public List<(double X, double Y, double W, double H)?> ContentBoxes = new();
            public void Dispose()
            {
                Pdf?.Dispose();
                Form?.Dispose();
                Image?.Dispose();
            }
        }

        /// <summary>打开源文件（PDF 逐页转 XForm；图片载为 XImage）。失败返回 null 并记入 Skipped。</summary>
        private SourceDoc? OpenSource(BillInfo bill)
        {
            var name = bill.SourceFile;
            if (_docCache.TryGetValue(name, out var cached)) return cached;

            SourceDoc? result = null;
            var path = Path.Combine(_originals, name);
            if (!File.Exists(path))
            {
                _skipped.Add($"{name}：原文件不存在");
            }
            else
            {
                var ext = Path.GetExtension(name).ToLowerInvariant();
                try
                {
                    if (ext == ".pdf")
                    {
                        var doc = new SourceDoc
                        {
                            Pdf = PdfReader.Open(path, PdfDocumentOpenMode.Import),
                            Form = XPdfForm.FromFile(path),
                        };
                        foreach (var p in doc.Pdf.Pages)
                        {
                            // 视觉尺寸：页面带 /Rotate 90/270 时宽高互换
                            var rotated = p.Rotate % 180 != 0;
                            var w = rotated ? p.Height.Point : p.Width.Point;
                            var h = rotated ? p.Width.Point : p.Height.Point;
                            doc.PdfPageDims.Add((w, h));
                            doc.PageBoxes.Add(PdfPageBoxes.FromPage(p));
                        }
                        // 内容边框（旋转贴页按内容 fit 用）：仅对无 /Rotate 的页计算，
                        // PdfPig 坐标在旋转页上语义不同，宁可回退整页 fit
                        var allow = new List<bool>();
                        foreach (var p in doc.Pdf.Pages) allow.Add(p.Rotate % 360 == 0);
                        doc.ContentBoxes = PageContentBox.Compute(path, allow, doc.PdfPageDims, doc.PageBoxes);
                        result = doc;
                    }
                    else if (ext is ".jpg" or ".jpeg" or ".png" or ".bmp")
                    {
                        var img = XImage.FromFile(path);
                        result = new SourceDoc { Image = img };
                    }
                    else
                    {
                        _skipped.Add($"{name}：格式 {ext} 暂不支持整合排版");
                    }
                }
                catch (Exception e)
                {
                    _skipped.Add($"{name}：打开失败（{e.Message}）");
                    result?.Dispose();
                    result = null;
                }
            }
            _docCache[name] = result;
            return result;
        }

        /// <summary>源的逻辑页数（PDF 页数；图片为 1；打不开为 0）。</summary>
        private int PageCountOf(BillInfo bill)
        {
            var doc = OpenSource(bill);
            if (doc == null) return 0;
            return doc.Pdf != null ? doc.PdfPageDims.Count : 1;
        }

        // MARK: 页面与贴页

        private void NewPage()
        {
            _gfx?.Dispose();
            _page = _output.AddPage();
            _page.Width = XUnit.FromPoint(A4W);
            _page.Height = XUnit.FromPoint(A4H);
            _gfx = XGraphics.FromPdfPage(_page);
            _pageIndex = _output.PageCount;
        }

        private void EnsurePage()
        {
            if (_page == null) NewPage();
        }

        /// <summary>把一个源页贴进 rect（等比 fit + 居中；rotation=-90 时左旋）。</summary>
        private void Place(BillInfo bill, int sourcePage, (double X, double Y, double W, double H) rect,
            int rotation, string rule)
        {
            var doc = OpenSource(bill);
            if (doc == null) return;
            EnsurePage();

            double srcW, srcH;
            XPdfForm? form = null;
            if (doc.Pdf != null)
            {
                if (sourcePage >= doc.PdfPageDims.Count) return;
                form = doc.Form!;
                form.PageNumber = sourcePage + 1; // XPdfForm 页号从 1 起
                (srcW, srcH) = doc.PdfPageDims[sourcePage];
            }
            else
            {
                srcW = doc.Image!.PointWidth;
                srcH = doc.Image.PointHeight;
            }

            // 旋转贴页的内容边框（外扩 10pt 容纳边框线/印章）先做健全性校验：
            // 边框越界/过小/几乎整页时一律不用，回退整页 fit——宁可发票小，不出空白页。
            (double X, double Y, double W, double H)? crop = null;
            if (rotation != 0 && form != null && sourcePage < doc.ContentBoxes.Count
                && doc.ContentBoxes[sourcePage] is { } content)
            {
                const double pad = 10.0;
                var cx0 = Math.Max(0, content.X - pad);
                var cy0 = Math.Max(0, content.Y - pad);
                var cw = Math.Min(srcW, content.X + content.W + pad) - cx0;
                var ch = Math.Min(srcH, content.Y + content.H + pad) - cy0;
                if (cw >= 30 && ch >= 30 && cw * ch <= 0.97 * srcW * srcH)
                    crop = (cx0, cy0, cw, ch);
            }

            double fitW, fitH, boxX, boxY;
            if (rotation == 0)
            {
                var s = Math.Min(rect.W / srcW, rect.H / srcH);
                fitW = srcW * s; fitH = srcH * s;
                boxX = rect.X + (rect.W - fitW) / 2;
                boxY = rect.Y + (rect.H - fitH) / 2;
                var target = new XRect(boxX, boxY, fitW, fitH);
                if (form != null) _gfx!.DrawImage(form, target);
                else _gfx!.DrawImage(doc.Image!, target);
            }
            else if (crop is { } cb)
            {
                // 左旋 90° + 按内容边框 fit：源页是 A4 竖版、发票本体只占一部分时，
                // 先裁到内容边框再旋转，发票才能占满单元格（整页 fit 会被空白拖小）。
                var s = Math.Min(rect.W / cb.H, rect.H / cb.W);
                fitW = cb.H * s; fitH = cb.W * s;
                boxX = rect.X + (rect.W - fitW) / 2;
                boxY = rect.Y + (rect.H - fitH) / 2;
                var state = _gfx!.Save();
                _gfx.IntersectClip(new XRect(rect.X, rect.Y, rect.W, rect.H));
                _gfx.TranslateTransform(boxX + fitW / 2, boxY + fitH / 2);
                _gfx.RotateTransform(rotation);
                _gfx.ScaleTransform(s, s);
                _gfx.TranslateTransform(-(cb.X + cb.W / 2), -(cb.Y + cb.H / 2));
                _gfx.DrawImage(form!, new XRect(0, 0, srcW, srcH));
                _gfx.Restore(state);
            }
            else
            {
                // 左旋 90°：视觉宽高 = 源高×源宽 的等比 fit
                var s = Math.Min(rect.W / srcH, rect.H / srcW);
                fitW = srcH * s; fitH = srcW * s;
                boxX = rect.X + (rect.W - fitW) / 2;
                boxY = rect.Y + (rect.H - fitH) / 2;
                var state = _gfx!.Save();
                _gfx.TranslateTransform(boxX + fitW / 2, boxY + fitH / 2);
                _gfx.RotateTransform(rotation);
                _gfx.TranslateTransform(-fitH / 2, -fitW / 2);
                // 旋转坐标系里的绘制框：宽 = fitH（源宽方向），高 = fitW（源高方向）
                var local = new XRect(0, 0, fitH, fitW);
                if (form != null) _gfx.DrawImage(form, local);
                else _gfx.DrawImage(doc.Image!, local);
                _gfx.Restore(state);
            }
            _placements.Add(new PlacedItem(_pageIndex, bill.SourceFile, sourcePage, rule,
                boxX, boxY, fitW, fitH, rotation));
        }

        /// <summary>网格流：按 cols×rows 逐格贴，满页换页。</summary>
        private sealed class GridFlow
        {
            public int Cols, Rows, Rotation, CellIndex;
            public required string Rule;
        }

        private GridFlow NewFlow(int cols, int rows, int rotation, string rule) =>
            new() { Cols = cols, Rows = rows, Rotation = rotation, Rule = rule, CellIndex = 0 };

        private void Feed(GridFlow flow, BillInfo bill)
        {
            var pages = PageCountOf(bill);
            for (var p = 0; p < pages; p++)
            {
                var per = flow.Cols * flow.Rows;
                var idx = flow.CellIndex % per;
                if (idx == 0) NewPage();
                var rect = CellRect(idx % flow.Cols, idx / flow.Cols, flow.Cols, flow.Rows);
                Place(bill, p, rect, flow.Rotation, flow.Rule);
                flow.CellIndex++;
            }
        }

        private void PlaceFull(BillInfo bill, string rule)
        {
            var pages = PageCountOf(bill);
            for (var p = 0; p < pages; p++)
            {
                NewPage();
                Place(bill, p, FullRect, 0, rule);
            }
        }

        /// <summary>整页左旋贴页（滴滴单张发票用）。</summary>
        private void PlaceFullRotated(BillInfo bill, string rule)
        {
            var pages = PageCountOf(bill);
            for (var p = 0; p < pages; p++)
            {
                NewPage();
                Place(bill, p, FullRect, -90, rule);
            }
        }

        /// <summary>酒店发票：每一源页单独成页，上下两格各贴一份（同张两份）。</summary>
        private void PlaceDuplicated1x2(BillInfo bill, string rule)
        {
            var pages = PageCountOf(bill);
            for (var p = 0; p < pages; p++)
            {
                NewPage();
                Place(bill, p, CellRect(0, 0, 1, 2), 0, rule);
                Place(bill, p, CellRect(0, 1, 1, 2), 0, rule);
            }
        }

        // MARK: 容器排版（一个行程或本地）

        public void ComposeContainer(IReadOnlyList<BillInfo> bills, bool isLocal)
        {
            string FirstMmdd(BillInfo b) =>
                b.DateMMDDs.FirstOrDefault(x => x.Length > 0) is { Length: > 0 } m ? BillInfo.Take(m, 4) : "9999";

            var transports = bills
                .Where(b => b.BillType is BillType.TrainTicket or BillType.FlightItinerary or BillType.BoardingPass)
                .OrderBy(b => FirstMmdd(b), StringComparer.Ordinal).ToList();
            var selfSheets = bills.Where(b => b.BillType == BillType.SelfDriveSheet).ToList();
            var selfInvoices = bills.Where(b => b.BillType == BillType.GasInvoice).ToList()
                .Concat(bills.Where(b => b.BillType == BillType.TollInvoice)
                    .OrderBy(b => b.DidiLetter, StringComparer.Ordinal)).ToList();
            var folios = bills.Where(b => b.BillType == BillType.HotelFolio)
                .OrderBy(b => b.DateRange.Start, StringComparer.Ordinal).ToList();
            var invoices = bills.Where(b => b.BillType == BillType.HotelInvoice)
                .OrderBy(b => b.DateRange.Start, StringComparer.Ordinal).ToList();
            var didiForms = bills.Where(b => b.BillType == BillType.DidiTrip)
                .OrderBy(b => b.DidiLetter.Length == 0 ? "ZZZ" : b.DidiLetter, StringComparer.Ordinal).ToList();
            var didiInvoices = bills.Where(b => b.BillType == BillType.DidiInvoice)
                .OrderBy(b => b.DidiLetter.Length == 0 ? "ZZZ" : b.DidiLetter, StringComparer.Ordinal).ToList();
            var dining = bills.Where(b => b.BillType == BillType.Dining)
                .OrderBy(b => FirstMmdd(b), StringComparer.Ordinal).ToList();
            var telecom = bills.Where(b => b.BillType == BillType.Telecom)
                .OrderBy(b => FirstMmdd(b), StringComparer.Ordinal).ToList();

            if (!isLocal)
            {
                // 自驾：行程单整页 → 加油/通行费左旋 2×2
                foreach (var s in selfSheets) PlaceFull(s, "self-drive-sheet");
                if (selfInvoices.Count > 0)
                {
                    var f = NewFlow(2, 2, -90, "self-drive-invoice-2x2");
                    foreach (var b in selfInvoices) Feed(f, b);
                }

                // P1 行程证明页：去程（最早）+ 回程（最晚）第 0 页上下排
                BillInfo? outbound = transports.Count >= 1 ? transports[0] : null;
                BillInfo? returnt = transports.Count >= 2 ? transports[^1] : null;
                var p1Shown = new HashSet<BillInfo>();
                if (outbound != null && returnt != null)
                {
                    NewPage();
                    Place(outbound, 0, CellRect(0, 0, 1, 2), 0, "transport-pair");
                    Place(returnt, 0, CellRect(0, 1, 1, 2), 0, "transport-pair");
                    p1Shown.Add(outbound);
                    p1Shown.Add(returnt);
                }

                // 交通 3×2：非登机牌全页 + 未上 P1 的登机牌全页（修复 toolkit 登机牌消失）
                var gridSources = transports.Where(t =>
                    t.BillType != BillType.BoardingPass || !p1Shown.Contains(t)).ToList();
                if (gridSources.Count > 0)
                {
                    var f = NewFlow(3, 2, 0, "transport-3x2");
                    foreach (var b in gridSources) Feed(f, b);
                }
            }
            else
            {
                // 本地通信：1×2 上下（不复制）
                if (telecom.Count > 0)
                {
                    var f = NewFlow(1, 2, 0, "telecom-1x2");
                    foreach (var b in telecom) Feed(f, b);
                }
            }

            // 酒店：水单整页 + 发票同页两份，按金额配对穿插；未配对发票随后
            var usedInv = new HashSet<int>();
            foreach (var folio in folios)
            {
                PlaceFull(folio, "hotel-folio");
                var mi = -1;
                for (var i = 0; i < invoices.Count; i++)
                {
                    if (!usedInv.Contains(i) && Math.Abs(invoices[i].Amount - folio.Amount) < 0.01)
                    {
                        mi = i;
                        break;
                    }
                }
                if (mi >= 0)
                {
                    usedInv.Add(mi);
                    PlaceDuplicated1x2(invoices[mi], "hotel-invoice-1x2");
                }
            }
            for (var i = 0; i < invoices.Count; i++)
            {
                if (usedInv.Contains(i)) continue;
                if (isLocal)
                {
                    // 本地酒店发票在 toolkit 里走 other（丢弃）；这里走兜底 1×2（在 generic 段处理）
                    continue;
                }
                PlaceDuplicated1x2(invoices[i], "hotel-invoice-1x2");
            }

            // 滴滴行程单：1 份整页不旋转；多份左旋 1×2
            if (didiForms.Count == 1)
            {
                PlaceFull(didiForms[0], "didi-form-full");
            }
            else if (didiForms.Count > 1)
            {
                var f = NewFlow(1, 2, -90, "didi-form-1x2");
                foreach (var b in didiForms) Feed(f, b);
            }

            // 滴滴发票：1 份左旋整页；多份左旋 2×2
            if (didiInvoices.Count == 1)
            {
                PlaceFullRotated(didiInvoices[0], "didi-invoice-full");
            }
            else if (didiInvoices.Count > 1)
            {
                var f = NewFlow(2, 2, -90, "didi-invoice-2x2");
                foreach (var b in didiInvoices) Feed(f, b);
            }

            // 餐饮：左旋 2×2
            if (dining.Count > 0)
            {
                var f = NewFlow(2, 2, -90, "dining-2x2");
                foreach (var b in dining) Feed(f, b);
            }

            // 兜底（toolkit 丢弃的其他类）：1×2 上下不旋转——保证任何票据都出现在整合 PDF 里
            var handled = new HashSet<BillInfo>(transports.Concat(selfSheets).Concat(selfInvoices)
                .Concat(folios).Concat(didiForms).Concat(didiInvoices).Concat(dining).Concat(telecom));
            if (!isLocal) handled.UnionWith(invoices);
            var generic = bills.Where(b => !handled.Contains(b))
                .OrderBy(b => FirstMmdd(b), StringComparer.Ordinal).ToList();
            if (generic.Count > 0)
            {
                var f = NewFlow(1, 2, 0, "generic-1x2");
                foreach (var b in generic) Feed(f, b);
            }
        }

        public ComposeResult Save(string outputPath)
        {
            _gfx?.Dispose();
            _gfx = null;
            var dir = Path.GetDirectoryName(outputPath);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
            var pageCount = _output.PageCount; // PDFsharp 保存后文档不可再读，先取页数
            _output.Save(outputPath);
            return new ComposeResult(outputPath, pageCount, _placements, _skipped);
        }
    }
}
