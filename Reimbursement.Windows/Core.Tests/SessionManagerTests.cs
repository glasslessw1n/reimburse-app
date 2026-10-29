using Reimbursement.Core.Models;
using Reimbursement.Core.Storage;
using Xunit;

namespace Reimbursement.Core.Tests;

/// <summary>
/// 文件名生成、滴滴发票↔行程单配对、酒店匹配消歧、滴滴字母编号（由 Swift SessionManagerTests 逐条翻译）。
/// </summary>
public class SessionManagerTests
{
    // MARK: - BuildFilename

    [Fact]
    public void BuildFilenameHotelFolio()
    {
        var bill = new BillInfo(BillType.HotelFolio, 1200, "水单.pdf", new Dictionary<string, string?>
        {
            ["hotel_name"] = "厦门某酒店",
            ["check_in_date"] = "2026-09-10",
            ["check_out_date"] = "2026-09-12",
            ["city"] = "厦门",
        });
        Assert.Equal("0910-0912 厦门住宿水单.pdf", SessionManager.BuildFilename(bill));
    }

    [Fact]
    public void BuildFilenameDidiTripWithLetter()
    {
        var bill = new BillInfo(BillType.DidiTrip, 64, "a.pdf", new Dictionary<string, string?>
        {
            ["departure_date"] = "2026-09-15",
        });
        bill.DidiLetter = "A";
        Assert.Equal("滴滴出行行程报销单A.pdf", SessionManager.BuildFilename(bill));
    }

    [Fact]
    public void BuildFilenameOtherFallsBackToSourceName()
    {
        var bill = new BillInfo(BillType.Other, sourceFile: "报销单据.pdf");
        Assert.Equal("报销单据.pdf", SessionManager.BuildFilename(bill));
    }

    [Fact]
    public void BuildFilenameDining()
    {
        var bill = new BillInfo(BillType.Dining, 580, "餐饮.pdf", new Dictionary<string, string?>
        {
            ["issue_date"] = "2026-09-16",
        });
        Assert.Equal("0916 餐饮发票 580.pdf", SessionManager.BuildFilename(bill));
    }

    // MARK: - 滴滴配对

    /// <summary>滴滴发票按金额配对到行程单后，应继承行程单日期（用于归到同一行程）。</summary>
    [Fact]
    public void LinkDidiInvoicesCopiesTripDateToInvoice()
    {
        var trip = new BillInfo(BillType.DidiTrip, 172.9, "trip.pdf", new Dictionary<string, string?>
        {
            ["departure_date"] = "2026-09-22",
        });
        var invoice = new BillInfo(BillType.DidiInvoice, 172.9, "inv.pdf", new Dictionary<string, string?>
        {
            ["issue_date"] = "2026-09-26",
        });
        var bills = new List<BillInfo> { trip, invoice };
        SessionManager.LinkDidiInvoices(bills);
        Assert.Equal(new[] { "0922" }, bills[1].DateMMDDs);
        Assert.Equal("2026-09-22", bills[1].DateRange.Start);
    }

    /// <summary>金额不匹配的发票不应被改动。</summary>
    [Fact]
    public void LinkDidiInvoicesLeavesUnmatchedInvoice()
    {
        var trip = new BillInfo(BillType.DidiTrip, 100, "trip.pdf", new Dictionary<string, string?>
        {
            ["departure_date"] = "2026-09-22",
        });
        var invoice = new BillInfo(BillType.DidiInvoice, 999, "inv.pdf", new Dictionary<string, string?>
        {
            ["issue_date"] = "2026-09-26",
        });
        var bills = new List<BillInfo> { trip, invoice };
        SessionManager.LinkDidiInvoices(bills);
        Assert.Equal(new[] { "0926" }, bills[1].DateMMDDs);
    }

    // MARK: - 酒店水单↔发票匹配

    /// <summary>金额相同的两家酒店，发票应按酒店名相似度匹配到正确那家（而非只看金额）。</summary>
    [Fact]
    public void HotelMatchDisambiguatesSameAmountByName()
    {
        var bills = new List<BillInfo>
        {
            new(BillType.HotelFolio, 800, "folio_sh.pdf", new Dictionary<string, string?>
            {
                ["hotel_name"] = "上海外滩茂悦大酒店", ["city"] = "上海",
                ["check_in_date"] = "2026-09-10", ["check_out_date"] = "2026-09-12",
            }),
            new(BillType.HotelFolio, 800, "folio_gz.pdf", new Dictionary<string, string?>
            {
                ["hotel_name"] = "广州珠江大酒店", ["city"] = "广州",
                ["check_in_date"] = "2026-09-10", ["check_out_date"] = "2026-09-12",
            }),
            new(BillType.HotelInvoice, 800, "inv.pdf", new Dictionary<string, string?>
            {
                ["seller_name"] = "上海外滩茂悦大酒店", ["issue_date"] = "2026-09-12",
            }),
        };
        SessionManager.MatchAndEnrichHotel(bills);
        var invoice = bills[2];
        Assert.Equal("上海外滩茂悦大酒店", invoice.F("hotel_name"));
        Assert.Equal(new[] { "上海" }, invoice.Cities);
    }

    // MARK: - 滴滴字母按时间先后编号

    [Fact]
    public void AssignSequencesChronologicalLetters()
    {
        var container = new List<BillInfo>
        {
            new(BillType.DidiTrip, 202.7, "b.pdf", new Dictionary<string, string?>
            {
                ["departure_date"] = "2026-09-10", ["trip_period"] = "2026-09-10 17:13 至 2026-09-12 09:52",
            }),
            new(BillType.DidiTrip, 171.6, "a.pdf", new Dictionary<string, string?>
            {
                ["departure_date"] = "2026-09-10", ["trip_period"] = "2026-09-10 11:24 至 2026-09-12 14:04",
            }),
        };
        SessionManager.AssignSequences(container);
        // 11:24 的 171.6 → A；17:13 的 202.7 → B（按时间先后，而非上传顺序）
        Assert.Equal("B", container[0].DidiLetter);
        Assert.Equal("A", container[1].DidiLetter);
    }

    [Fact]
    public void AssignSequencesInvoiceMatchesTripLetter()
    {
        var container = new List<BillInfo>
        {
            new(BillType.DidiTrip, 171.6, "t1.pdf", new Dictionary<string, string?>
            {
                ["departure_date"] = "2026-09-10",
            }),
            new(BillType.DidiInvoice, 171.6, "i1.pdf", new Dictionary<string, string?>
            {
                ["issue_date"] = "2026-09-26",
            }),
        };
        SessionManager.AssignSequences(container);
        Assert.Equal("A", container[0].DidiLetter);
        Assert.Equal("A", container[1].DidiLetter); // 发票按金额匹配行程单的字母
    }
}

/// <summary>
/// 会话端到端冒烟（新增覆盖）：建会话 → 存原文件 → ingest → finalize → arrange → 打包，
/// 断言 manifest 落盘重读一致、trips 目录结构与 zip 内容正确。
/// </summary>
public class SessionFlowTests
{
    [Fact]
    public void FullFlowProducesTripsAndZip()
    {
        var root = Path.Combine(Path.GetTempPath(), "reimburse-flow-" + Guid.NewGuid().ToString("N"));
        var sessionsRoot = Path.Combine(root, "sessions");
        var downloads = Path.Combine(root, "downloads");
        var sid = Sessions.CreateNewSid();
        try
        {
            var session = new SessionManager(sessionsRoot, sid);
            var home = new HashSet<string> { "重庆" };

            BillInfo Make(BillType t, double amt, string src, Dictionary<string, string?> fields)
            {
                session.SaveOriginal(new byte[] { 1, 2, 3 }, src);
                return new BillInfo(t, amt, src, fields);
            }

            session.Ingest(Make(BillType.BoardingPass, 800, "bp1.pdf", new()
            {
                ["departure_date"] = "2026-09-10", ["origin_city"] = "重庆", ["destination_city"] = "厦门",
            }));
            session.Ingest(Make(BillType.HotelFolio, 1200, "folio.pdf", new()
            {
                ["hotel_name"] = "厦门某酒店", ["check_in_date"] = "2026-09-10",
                ["check_out_date"] = "2026-09-12", ["city"] = "厦门",
            }));
            session.Ingest(Make(BillType.BoardingPass, 820, "bp2.pdf", new()
            {
                ["departure_date"] = "2026-09-12", ["origin_city"] = "厦门", ["destination_city"] = "重庆",
            }));

            session.Finalize(home);

            Assert.Single(session.Manifest.Trips);
            Assert.Equal(3, session.Manifest.Trips[0].Bills.Count);
            Assert.Equal("0910-0912 厦门", session.Manifest.Trips[0].Dirname);

            // manifest 重读一致
            var reloaded = new SessionManager(sessionsRoot, sid);
            Assert.Equal(3, reloaded.Manifest.Bills.Count);
            Assert.Single(Sessions.List(sessionsRoot));

            // arrange + 打包
            Packaging.ZipPackager.ArrangeFiles(session);
            var tripDir = Path.Combine(session.RootDir, "trips", "0910-0912 厦门");
            Assert.True(File.Exists(Path.Combine(tripDir, "0910-0912 厦门住宿水单.pdf")));

            var zipPath = Packaging.ZipPackager.Package(session, downloads, includeExcel: false);
            Assert.True(File.Exists(zipPath));
            using var zip = System.IO.Compression.ZipFile.OpenRead(zipPath);
            Assert.Contains(zip.Entries, e => e.FullName.Contains("住宿水单"));
            Assert.Contains(zip.Entries, e => e.FullName.Contains("登机牌"));
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public void FinalizeAloneArrangesTripsSoPackageWorks()
    {
        // 回归（2026-10-30 用户实测）：Windows 版曾漏接 ArrangeFiles，finalize 后 trips/ 不存在，
        // 点「完整打包」恒失败且无产物。现在 Finalize 内部即完成 arrange，不再需要手动补调。
        var root = Path.Combine(Path.GetTempPath(), "reimburse-flow2-" + Guid.NewGuid().ToString("N"));
        var sessionsRoot = Path.Combine(root, "sessions");
        var downloads = Path.Combine(root, "downloads");
        var sid = Sessions.CreateNewSid();
        try
        {
            var session = new SessionManager(sessionsRoot, sid);
            var home = new HashSet<string> { "重庆" };
            session.SaveOriginal(new byte[] { 1, 2, 3 }, "bp1.pdf");
            session.Ingest(new BillInfo(BillType.BoardingPass, 800, "bp1.pdf", new()
            {
                ["departure_date"] = "2026-09-10", ["origin_city"] = "重庆", ["destination_city"] = "厦门",
            }));
            session.SaveOriginal(new byte[] { 4, 5, 6 }, "bp2.pdf");
            session.Ingest(new BillInfo(BillType.BoardingPass, 820, "bp2.pdf", new()
            {
                ["departure_date"] = "2026-09-12", ["origin_city"] = "厦门", ["destination_city"] = "重庆",
            }));

            session.Finalize(home);

            // 未手动 ArrangeFiles，trips/ 应已被 Finalize 建好
            var tripDir = Path.Combine(session.RootDir, "trips", "0910-0912 厦门");
            Assert.True(Directory.Exists(tripDir));
            Assert.Equal(2, Directory.GetFiles(tripDir).Length);

            var zipPath = Packaging.ZipPackager.Package(session, downloads, includeExcel: false);
            Assert.True(File.Exists(zipPath));
            using var zip = System.IO.Compression.ZipFile.OpenRead(zipPath);
            Assert.Equal(2, zip.Entries.Count(e => e.FullName.Contains("登机牌")));
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
        }
    }
}
