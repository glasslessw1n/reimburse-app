using PdfSharp.Drawing;
using PdfSharp.Pdf;
using PdfSharp.Pdf.IO;
using Reimbursement.Core.Models;
using Reimbursement.Core.Packaging;
using Reimbursement.Core.Storage;
using Xunit;

namespace Reimbursement.Core.Tests;

/// <summary>
/// toolkit 融入验证：Compose 排版规则/三缺陷修复、Merge 顺序与页数、Preflight 检查项。
/// 源文件用 PDFsharp 现场合成（空白页 + 色块，无需字体），断言以 Compose 的贴页清单为准。
/// </summary>
public class ToolkitMergeTests
{
    private static byte[] MakePdfBytes(int pages, double w = 595, double h = 842)
    {
        using var doc = new PdfDocument();
        for (var i = 0; i < pages; i++)
        {
            var page = doc.AddPage();
            page.Width = XUnit.FromPoint(w);
            page.Height = XUnit.FromPoint(h);
            using var gfx = XGraphics.FromPdfPage(page);
            gfx.DrawRectangle(XBrushes.LightGray, new XRect(10, 10, w - 20, h - 20));
        }
        using var ms = new MemoryStream();
        doc.Save(ms);
        return ms.ToArray();
    }

    private sealed class Fixture : IDisposable
    {
        public string Root = Path.Combine(Path.GetTempPath(), "reimburse-compose-" + Guid.NewGuid().ToString("N"));
        public SessionManager Session = null!;
        public HashSet<string> Home = new() { "重庆" };

        public Fixture Build(Action<Fixture> add)
        {
            var sessionsRoot = Path.Combine(Root, "sessions");
            Session = new SessionManager(sessionsRoot, Sessions.CreateNewSid());
            add(this);
            Session.Finalize(Home);
            return this;
        }

        public void Add(BillType type, double amount, string src, int pages,
            Dictionary<string, string?> fields, double w = 595, double h = 842)
        {
            Session.SaveOriginal(MakePdfBytes(pages, w, h), src);
            Session.Ingest(new BillInfo(type, amount, src, fields));
        }

        public void AddRaw(BillType type, double amount, string src, byte[] pdf,
            Dictionary<string, string?> fields)
        {
            Session.SaveOriginal(pdf, src);
            Session.Ingest(new BillInfo(type, amount, src, fields));
        }

        public void Dispose()
        {
            if (Directory.Exists(Root)) Directory.Delete(Root, recursive: true);
        }
    }

    /// <summary>标准行程：登机牌去/回 + 中间火车票(2页) + 酒店一对 + 滴滴一对 + 餐饮。</summary>
    private static Fixture StandardTrip() => new Fixture().Build(f =>
    {
        f.Add(BillType.BoardingPass, 800, "bp1.pdf", 1, new()
        {
            ["departure_date"] = "2026-09-10", ["origin_city"] = "重庆", ["destination_city"] = "厦门",
        });
        f.Add(BillType.TrainTicket, 300, "train.pdf", 2, new()
        {
            ["departure_date"] = "2026-09-11", ["origin_city"] = "厦门", ["destination_city"] = "福州",
        });
        f.Add(BillType.BoardingPass, 820, "bp2.pdf", 1, new()
        {
            ["departure_date"] = "2026-09-12", ["origin_city"] = "福州", ["destination_city"] = "重庆",
        });
        f.Add(BillType.HotelFolio, 1200, "folio.pdf", 1, new()
        {
            ["hotel_name"] = "厦门某酒店", ["check_in_date"] = "2026-09-10",
            ["check_out_date"] = "2026-09-12", ["city"] = "厦门",
        });
        f.Add(BillType.HotelInvoice, 1200, "hinv.pdf", 1, new()
        {
            ["issue_date"] = "2026-09-12", ["seller_name"] = "厦门某酒店",
        });
        f.Add(BillType.DidiTrip, 85.5, "dform.pdf", 1, new()
        {
            ["departure_date"] = "2026-09-11",
        });
        f.Add(BillType.DidiInvoice, 85.5, "dinv.pdf", 1, new()
        {
            ["issue_date"] = "2026-09-13",
        }, w: 842, h: 595); // 横版发票，验证左旋 fit
        f.Add(BillType.Dining, 200, "dining.pdf", 1, new()
        {
            ["issue_date"] = "2026-09-11",
        });
    });

    [Fact]
    public void ComposeStandardTripLayoutRules()
    {
        using var f = StandardTrip();
        var outPath = Path.Combine(f.Root, PdfComposer.SuggestFileName(f.Session));
        var result = PdfComposer.Compose(f.Session, outPath);

        Assert.Equal("报销单整合_0910-0912.pdf", Path.GetFileName(outPath));
        Assert.True(File.Exists(outPath));
        // P1 + 交通网格 + 水单 + 发票页 + 滴滴行程单 + 滴滴发票 + 餐饮 = 7 页
        Assert.Equal(7, result.PageCount);
        using (var doc = PdfReader.Open(outPath, PdfDocumentOpenMode.Import))
            Assert.Equal(7, doc.PageCount);
        Assert.Empty(result.Skipped);

        int ByRule(string rule) => result.Placements.Count(p => p.Rule == rule);
        Assert.Equal(2, ByRule("transport-pair"));          // P1 去+回
        Assert.Equal(2, ByRule("transport-3x2"));           // 火车票 2 页（多页修复：第二页也在）
        Assert.Contains(result.Placements, p => p.SourceFile == "train.pdf" && p.SourcePageIndex == 1);
        Assert.Equal(1, ByRule("hotel-folio"));
        Assert.Equal(2, ByRule("hotel-invoice-1x2"));       // 同张发票上下两份
        Assert.Equal(1, ByRule("didi-form-full"));
        Assert.Equal(1, ByRule("didi-invoice-full"));
        Assert.Equal(1, ByRule("dining-2x2"));
        Assert.Equal(10, result.Placements.Count);

        // P1 两张都在第 1 页；登机牌没有重复进网格
        Assert.All(result.Placements.Where(p => p.Rule == "transport-pair"),
            p => Assert.Equal(1, p.OutputPage));
        Assert.DoesNotContain(result.Placements,
            p => p.Rule == "transport-3x2" && p.SourceFile.StartsWith("bp"));

        // 横版滴滴发票左旋后：贴页框宽≈整页可用宽（555.28），且记录旋转 -90
        var dinv = result.Placements.Single(p => p.Rule == "didi-invoice-full");
        Assert.Equal(-90, dinv.Rotation);
        Assert.InRange(dinv.Width, 554.0, 556.0);
    }

    /// <summary>滴滴发票式源页：A4 竖版，内容只占顶部约一半（边框 + 色块），下半页空白。</summary>
    private static byte[] MakeTopContentPdfBytes()
    {
        using var doc = new PdfDocument();
        var page = doc.AddPage();
        page.Width = XUnit.FromPoint(595);
        page.Height = XUnit.FromPoint(842);
        using var gfx = XGraphics.FromPdfPage(page);
        gfx.DrawRectangle(new XPen(XColors.DarkRed, 1.5), new XRect(8, 8, 579, 405));
        gfx.DrawRectangle(XBrushes.LightGray, new XRect(8, 120, 579, 60));
        gfx.DrawRectangle(XBrushes.LightGray, new XRect(8, 330, 579, 40));
        using var ms = new MemoryStream();
        doc.Save(ms);
        return ms.ToArray();
    }

    [Fact]
    public void ComposeDidiInvoicesWithTopOnlyContentFill2x2Cells()
    {
        // 用户实测问题（2026-10-30）：真实滴滴发票是 A4 竖版承载、发票本体只占上半页，
        // 左旋后按整页 fit 被空白拖小（高仅约 192pt，占不满）；按内容边框 fit 后应占满 2×2 单元格。
        using var f = new Fixture().Build(x =>
        {
            x.Add(BillType.BoardingPass, 800, "bp1.pdf", 1, new()
            {
                ["departure_date"] = "2026-09-10", ["origin_city"] = "重庆", ["destination_city"] = "厦门",
            });
            x.Add(BillType.BoardingPass, 820, "bp2.pdf", 1, new()
            {
                ["departure_date"] = "2026-09-12", ["origin_city"] = "厦门", ["destination_city"] = "重庆",
            });
            x.Add(BillType.DidiTrip, 85.5, "dform1.pdf", 1, new() { ["departure_date"] = "2026-09-11" });
            x.Add(BillType.DidiTrip, 92.0, "dform2.pdf", 1, new() { ["departure_date"] = "2026-09-11" });
            x.AddRaw(BillType.DidiInvoice, 85.5, "dinv1.pdf", MakeTopContentPdfBytes(),
                new() { ["issue_date"] = "2026-09-13" });
            x.AddRaw(BillType.DidiInvoice, 92.0, "dinv2.pdf", MakeTopContentPdfBytes(),
                new() { ["issue_date"] = "2026-09-13" });
        });
        var result = PdfComposer.Compose(f.Session, Path.Combine(f.Root, "out.pdf"));
        var cells = result.Placements.Where(p => p.Rule == "didi-invoice-2x2").ToList();
        Assert.Equal(2, cells.Count);
        Assert.Equal(cells[0].OutputPage, cells[1].OutputPage);
        Assert.All(cells, p =>
        {
            Assert.Equal(-90, p.Rotation);
            Assert.InRange(p.Width, 265.0, 274.0);   // 单元格宽 273.64：内容应基本占满
            Assert.InRange(p.Height, 360.0, 397.0);  // 整页 fit 时仅约 192
        });
    }

    [Fact]
    public void ComposeSingleBoardingPassNotDropped()
    {
        // toolkit 缺陷复现防线：只有一张登机牌（凑不成 P1 去/回对）时不应消失
        using var f = new Fixture().Build(x =>
        {
            x.Add(BillType.BoardingPass, 800, "only-bp.pdf", 1, new()
            {
                ["departure_date"] = "2026-09-10", ["origin_city"] = "重庆", ["destination_city"] = "厦门",
            });
            x.Add(BillType.HotelFolio, 600, "folio.pdf", 1, new()
            {
                ["hotel_name"] = "厦门某酒店", ["check_in_date"] = "2026-09-10",
                ["check_out_date"] = "2026-09-11", ["city"] = "厦门",
            });
        });
        var result = PdfComposer.Compose(f.Session, Path.Combine(f.Root, "out.pdf"));
        Assert.Contains(result.Placements,
            p => p.SourceFile == "only-bp.pdf" && p.Rule == "transport-3x2");
    }

    [Fact]
    public void MergeOrderAndPageCount()
    {
        using var f = StandardTrip();
        var ordered = PdfMerger.BuildOrderedList(f.Session);
        Assert.Equal(
            new[] { "bp1.pdf", "train.pdf", "bp2.pdf", "folio.pdf", "hinv.pdf", "dform.pdf", "dinv.pdf", "dining.pdf" },
            ordered.Select(o => o.Bill.SourceFile).ToArray());

        var result = PdfMerger.Merge(f.Session, Path.Combine(f.Root, "merged.pdf"));
        Assert.Empty(result.Skipped);
        Assert.Equal(9, result.PageCount); // train 2 页 + 其余 7 个 1 页
    }

    [Fact]
    public void PreflightDetectsIssues()
    {
        using var f = new Fixture().Build(x =>
        {
            x.Add(BillType.BoardingPass, 800, "bp1.pdf", 1, new()
            {
                ["departure_date"] = "2026-09-10", ["origin_city"] = "重庆", ["destination_city"] = "厦门",
            });
            x.Add(BillType.HotelFolio, 600, "folio.pdf", 1, new()
            {
                ["hotel_name"] = "厦门某酒店", ["check_in_date"] = "2026-09-10",
                ["check_out_date"] = "2026-09-11", ["city"] = "厦门",
            });
            x.Add(BillType.DidiTrip, 50, "dform.pdf", 1, new()
            {
                ["departure_date"] = "2026-09-10",
            });
        });
        var issues = Preflight.Check(f.Session, f.Home);
        Assert.Contains(issues, i => i.Category == "水单缺发票");
        Assert.Contains(issues, i => i.Category == "滴滴缺发票");
        Assert.Contains(issues, i => i.Category == "行程未见返程");
    }

    [Fact]
    public void PreflightCleanSessionHasNoIssues()
    {
        using var f = StandardTrip();
        var issues = Preflight.Check(f.Session, f.Home);
        Assert.Empty(issues);
    }
}
