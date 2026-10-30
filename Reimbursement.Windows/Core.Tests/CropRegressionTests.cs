using PdfSharp.Pdf;
using PdfSharp.Pdf.IO;
using Reimbursement.Core.Models;
using Reimbursement.Core.Packaging;
using Reimbursement.Core.Storage;
using PdfPigDocument = UglyToad.PdfPig.PdfDocument;

namespace Reimbursement.Core.Tests;

/// <summary>
/// 2026-10-30 滴滴发票空白页事故的回归防线。真实滴滴发票（用户原件实测）：
/// MediaBox=[0,0,595.3,841.9] 而 CropBox=[0,432.9,610,864]——可见带只有上半页。
/// 旧实现把 PdfPig 的裁剪框相对坐标当 MediaBox 坐标用，算出的"内容框"落在
/// 页面下半的空白带上，旋转贴页后整格空白。本组测试用与原件同框几何的
/// 合成发票（标准 Type1 字体、可见带内 9 行文字）锁死：内容框必须等于可见框、
/// 贴页必须占满单元格、输出页必须真有文字。修复另经用户真实原件 B/C.pdf
/// 在本地端到端渲染验证（发票完整可见），原件不入仓库。
/// </summary>
public class CropRegressionTests
{
    // 与真实滴滴发票同框几何的合成发票（MediaBox/CropBox 同上，Helvetica 文字在可见带内）
    private static readonly byte[] DidiLikePdf = Convert.FromBase64String(
        "JVBERi0xLjMKJb/3ov4KMSAwIG9iago8PCAvUGFnZXMgMiAwIFIgL1R5cGUgL0NhdGFsb2cgPj4K" +
        "ZW5kb2JqCjIgMCBvYmoKPDwgL0NvdW50IDEgL0tpZHMgWyAzIDAgUiBdIC9UeXBlIC9QYWdlcyA+" +
        "PgplbmRvYmoKMyAwIG9iago8PCAvQ29udGVudHMgNCAwIFIgL0Nyb3BCb3ggWyAwIDQzMi45IDYx" +
        "MCA4NjQgXSAvTWVkaWFCb3ggWyAwIDAgNTk1LjMgODQxLjkgXSAvUGFyZW50IDIgMCBSIC9SZXNv" +
        "dXJjZXMgPDwgL0ZvbnQgPDwgL0YxIDUgMCBSID4+ID4+IC9UeXBlIC9QYWdlID4+CmVuZG9iago0" +
        "IDAgb2JqCjw8IC9MZW5ndGggMzU5IC9GaWx0ZXIgL0ZsYXRlRGVjb2RlID4+CnN0cmVhbQp4nHWS" +
        "zW7jIBRG932KbzmzSAawwa53E8dTWUrTUYKqdols4tBxIMWkTd9+/KOqi8ogFle6HNC5HwXp9+4O" +
        "DO+gHHFCwAVH1B+vsb9ZSfz6Q0EjyAMigpQQyBo/1uW6RLEpcrl72JY5yu3jQ5kXwNaBCUoTMi7G" +
        "oiiOORc/IV9QyG+8RMQjb6/bVvsMK21ejG2wNrWB1NXRutY1H8gdNqGepbB0pKwuHwOkaPW/oLA/" +
        "KtsclcG9rk2lWhSvF3M+aRvmOOKWjZwy6FOGv6rrtG20R/DKdmfnAzrt30ylZwFcjIDfJ3exAfpa" +
        "tQjqmvXelkIAkEMRL9N4lsAmwdIF1WbIt89I+ZKTuX6eTgLXKmi4A0zXXXQGRphYkNsFjWYvxpMz" +
        "6c25f+fobPM6mF/gyaheEr4YdJZBJ1+P2ptDrzgYZ1G5uv8ApYRhGD766QskSZp+UsgYOt8MgRPx" +
        "FDi6HAN3uPkPERupLAplbmRzdHJlYW0KZW5kb2JqCjUgMCBvYmoKPDwgL0Jhc2VGb250IC9IZWx2" +
        "ZXRpY2EgL1N1YnR5cGUgL1R5cGUxIC9UeXBlIC9Gb250ID4+CmVuZG9iagp4cmVmCjAgNgowMDAw" +
        "MDAwMDAwIDY1NTM1IGYgCjAwMDAwMDAwMTUgMDAwMDAgbiAKMDAwMDAwMDA2NCAwMDAwMCBuIAow" +
        "MDAwMDAwMTIzIDAwMDAwIG4gCjAwMDAwMDAyODQgMDAwMDAgbiAKMDAwMDAwMDcxNSAwMDAwMCBu" +
        "IAp0cmFpbGVyIDw8IC9Sb290IDEgMCBSIC9TaXplIDYgL0lEIFs8NGQ3YjFkMGU1ZGFkY2RlODAx" +
        "MmU5NzRmYTE0YmQ4YTA+PDRkN2IxZDBlNWRhZGNkZTgwMTJlOTc0ZmExNGJkOGEwPl0gPj4Kc3Rh" +
        "cnR4cmVmCjc4NQolJUVPRgo=");

    private static (List<(double W, double H)> Dims, List<PdfPageBoxes> Boxes) GeomsOf(string path)
    {
        using var doc = PdfReader.Open(path, PdfDocumentOpenMode.Import);
        var dims = new List<(double, double)>();
        var boxes = new List<PdfPageBoxes>();
        foreach (var p in doc.Pages)
        {
            dims.Add((p.Width.Point, p.Height.Point));
            boxes.Add(PdfPageBoxes.FromPage(p));
        }
        return (dims, boxes);
    }

    [Fact]
    public void ContentBox_DidiLikeInvoice_IsTheVisibleBand()
    {
        var path = Path.Combine(Path.GetTempPath(), "didi-like-" + Guid.NewGuid().ToString("N") + ".pdf");
        try
        {
            File.WriteAllBytes(path, DidiLikePdf);
            var (dims, boxes) = GeomsOf(path);
            var result = PageContentBox.Compute(path, new[] { true }, dims, boxes);

            var box = Assert.Single(result);
            Assert.NotNull(box);
            // 可见框：x=0、y(左上原点)=0、宽=595.3、高=841.9-432.9=409.0
            Assert.InRange(box!.Value.X, -1, 3);
            Assert.InRange(box.Value.Y, -1, 3);
            Assert.InRange(box.Value.W, 592, 598);
            Assert.InRange(box.Value.H, 405, 413);
        }
        finally
        {
            if (File.Exists(path)) File.Delete(path);
        }
    }

    private sealed class Fixture : IDisposable
    {
        public string Root = Path.Combine(Path.GetTempPath(), "reimburse-crop-" + Guid.NewGuid().ToString("N"));
        public SessionManager Session = null!;

        public Fixture Build()
        {
            var sessionsRoot = Path.Combine(Root, "sessions");
            Session = new SessionManager(sessionsRoot, Sessions.CreateNewSid());
            void Add(BillType type, double amount, string src, byte[] pdf, Dictionary<string, string?> fields)
            {
                Session.SaveOriginal(pdf, src);
                Session.Ingest(new BillInfo(type, amount, src, fields));
            }
            // 两张登机牌锚定一段行程，滴滴发票两张随后
            Add(BillType.BoardingPass, 800, "bp1.pdf", SyntheticPdf(), new()
            {
                ["departure_date"] = "2026-09-10", ["origin_city"] = "重庆", ["destination_city"] = "厦门",
            });
            Add(BillType.BoardingPass, 820, "bp2.pdf", SyntheticPdf(), new()
            {
                ["departure_date"] = "2026-09-12", ["origin_city"] = "厦门", ["destination_city"] = "重庆",
            });
            Add(BillType.DidiInvoice, 85.5, "dinv-b.pdf", DidiLikePdf,
                new() { ["issue_date"] = "2026-09-13" });
            Add(BillType.DidiInvoice, 92.0, "dinv-c.pdf", DidiLikePdf,
                new() { ["issue_date"] = "2026-09-13" });
            Session.Finalize(new HashSet<string> { "重庆" });
            return this;
        }

        private static byte[] SyntheticPdf()
        {
            using var doc = new PdfSharp.Pdf.PdfDocument();
            var page = doc.AddPage();
            page.Width = PdfSharp.Drawing.XUnit.FromPoint(595);
            page.Height = PdfSharp.Drawing.XUnit.FromPoint(842);
            using var ms = new MemoryStream();
            doc.Save(ms);
            return ms.ToArray();
        }

        public void Dispose()
        {
            if (Directory.Exists(Root)) Directory.Delete(Root, recursive: true);
        }
    }

    [Fact]
    public void Compose_DidiLikeInvoices_FillCellsAndReallyRenderText()
    {
        using var f = new Fixture().Build();
        var outPath = Path.Combine(f.Root, "out.pdf");
        var result = PdfComposer.Compose(f.Session, outPath);

        var cells = result.Placements.Where(p => p.Rule == "didi-invoice-2x2").ToList();
        Assert.Equal(2, cells.Count);
        Assert.All(cells, p =>
        {
            Assert.Equal(-90, p.Rotation);
            Assert.InRange(p.Width, 265.0, 274.0);   // 单元格宽 273.64：内容应基本占满
            Assert.InRange(p.Height, 360.0, 397.0);  // 空白页事故时贴页几何同样"占满"，故还要验文字
        });

        // 像素级防线（文字代理）：输出的滴滴网格页上必须真有发票文字。
        // 事故版本该页 Letters=0（整页空白）；只断言 placements 几何是抓不住的。
        using var doc = PdfPigDocument.Open(outPath);
        var page = doc.GetPage(cells[0].OutputPage);
        Assert.True(page.Letters.Count >= 80,
            $"滴滴网格页文字数 {page.Letters.Count}，疑似空白页回归");
    }

    [Fact]
    public void Preflight_UnfinalizedSession_ReportsNotFinalized_AndToleratesNullFields()
    {
        var root = Path.Combine(Path.GetTempPath(), "reimburse-pf-" + Guid.NewGuid().ToString("N"));
        try
        {
            var session = new SessionManager(Path.Combine(root, "sessions"), Sessions.CreateNewSid());
            var bill = new BillInfo(BillType.DidiInvoice, 85.5, "dinv.pdf",
                new Dictionary<string, string?> { ["issue_date"] = "2026-09-13" });
            bill.Error = null!;          // 模拟旧 manifest 把非空字段反序列化成 null
            bill.ReviewReason = null!;
            session.Ingest(bill);

            var issues = Preflight.Check(session, new HashSet<string> { "重庆" });

            Assert.Contains(issues, i => i.Category == "尚未整理");
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public void ZipPackage_MissingOriginal_FailsLoudlyInsteadOfSilentlyDropping()
    {
        using var f = new Fixture().Build();
        // 删掉一张票据的原件后打包：过去会静默少装一张，现在必须报错点名
        File.Delete(Path.Combine(f.Session.RootDir, "originals", "dinv-b.pdf"));

        var missing = ZipPackager.ArrangeFiles(f.Session);
        Assert.Contains("dinv-b.pdf", missing);

        var ex = Assert.Throws<ZipPackager.PackageException>(() =>
            ZipPackager.Package(f.Session, Path.Combine(f.Root, "dl"), includeExcel: false));
        Assert.Contains("不完整", ex.Message);
    }

    [Fact]
    public void RemoveBill_RemovesFromTripCopiesToo()
    {
        using var f = new Fixture().Build();
        var tripBill = f.Session.Manifest.Trips.SelectMany(t => t.Bills).First();
        var uid = tripBill.Uid;

        f.Session.RemoveBill(uid);

        Assert.DoesNotContain(f.Session.Manifest.Bills, b => b.Uid == uid);
        Assert.All(f.Session.Manifest.Trips, t => Assert.DoesNotContain(t.Bills, b => b.Uid == uid));
        Assert.DoesNotContain(f.Session.Manifest.Local, b => b.Uid == uid);
    }
}
