using System.IO.Compression;
using System.Text;
using Reimbursement.Core.Models;
using Reimbursement.Core.Packaging;
using Xunit;

namespace Reimbursement.Core.Tests;

/// <summary>
/// ExcelBuilder 测试（由 Swift ExcelBuilderTests 逐条翻译）。
/// 覆盖 Excel 明细不丢票据（增值税合并后，行程内的兜底类型必须出现）。
/// </summary>
public class ExcelBuilderTests
{
    private static readonly HashSet<string> HomeCities = new() { "重庆" };

    private static Dictionary<string, string?> Fields(params (string Key, string Value)[] pairs)
    {
        var d = new Dictionary<string, string?>();
        foreach (var (k, v) in pairs) d[k] = v;
        return d;
    }

    [Fact]
    public void GenericTypesNotDroppedInTrip()
    {
        var bills = new List<BillInfo>
        {
            new(BillType.TrainTicket, amount: 553, sourceFile: "火车票.pdf",
                fields: Fields(("departure_date", "2026-09-10"), ("origin_city", "重庆"), ("destination_city", "厦门"))),
            new(BillType.TaxiTransport, amount: 30, sourceFile: "出租.pdf", fields: Fields(("issue_date", "2026-09-11"))),
            new(BillType.Telecom, amount: 200, sourceFile: "通信.pdf", fields: Fields(("issue_date", "2026-09-11"))),
            new(BillType.Other, amount: 100, sourceFile: "其他.pdf", fields: Fields(("issue_date", "2026-09-11"))),
        };
        var xml = ExcelBuilder.BuildSheet(bills, HomeCities);
        Assert.Contains("出租.pdf", xml); // 出租车票不应被漏掉
        Assert.Contains("通信.pdf", xml); // 通信票不应被漏掉
        Assert.Contains("其他.pdf", xml); // 其他票不应被漏掉
        Assert.Contains("报销总计", xml);
    }

    [Fact]
    public void LocalBillsAlsoRendered()
    {
        // 没有交通票 → 全落到「本地」，本地兜底也要渲染
        var bills = new List<BillInfo>
        {
            new(BillType.GasInvoice, amount: 300, sourceFile: "加油.pdf", fields: Fields(("issue_date", "2026-09-10"))),
            new(BillType.TollInvoice, amount: 50, sourceFile: "通行费.pdf", fields: Fields(("issue_date", "2026-09-11"))),
        };
        var xml = ExcelBuilder.BuildSheet(bills, HomeCities);
        Assert.Contains("加油.pdf", xml); // 加油票不应被漏掉
        Assert.Contains("通行费.pdf", xml); // 通行费不应被漏掉
    }

    [Fact]
    public void HotelFolioAndInvoiceCountedOnce()
    {
        // 水单+发票同金额 → 同一住宿只计一次，不能重复入表
        var bills = new List<BillInfo>
        {
            new(BillType.TrainTicket, amount: 553, sourceFile: "火车票.pdf",
                fields: Fields(("departure_date", "2026-09-10"), ("origin_city", "重庆"), ("destination_city", "厦门"))),
            new(BillType.HotelFolio, amount: 1200, sourceFile: "水单.pdf",
                fields: Fields(("check_in_date", "2026-09-10"), ("check_out_date", "2026-09-12"), ("city", "厦门"), ("hotel_name", "厦门酒店"))),
            new(BillType.HotelInvoice, amount: 1200, sourceFile: "发票.pdf",
                fields: Fields(("issue_date", "2026-09-12"), ("seller_name", "厦门酒店"))),
        };
        var xml = ExcelBuilder.BuildSheet(bills, HomeCities);
        var hotelCount = xml.Split("酒店住宿").Length - 1;
        Assert.Equal(1, hotelCount); // 水单+发票应归并为一行
        Assert.Contains("1753.00", xml); // 总计应为 553 + 1200 = 1753
        Assert.DoesNotContain("2953.00", xml); // 不应重复计入酒店金额
    }

    /// <summary>新增：Build 产出的 xlsx 是结构完整的 zip 包（6 个部件，工作簿 sheet 名正确）。</summary>
    [Fact]
    public void BuildProducesValidXlsxPackage()
    {
        var bills = new List<BillInfo>
        {
            new(BillType.Dining, amount: 580, sourceFile: "餐饮.pdf", fields: Fields(("issue_date", "2026-09-16"))),
        };
        var bytes = ExcelBuilder.Build(bills, HomeCities);
        using var zip = new ZipArchive(new MemoryStream(bytes), ZipArchiveMode.Read);
        var names = zip.Entries.Select(e => e.FullName).ToHashSet();
        Assert.Contains("[Content_Types].xml", names);
        Assert.Contains("_rels/.rels", names);
        Assert.Contains("xl/workbook.xml", names);
        Assert.Contains("xl/_rels/workbook.xml.rels", names);
        Assert.Contains("xl/worksheets/sheet1.xml", names);
        Assert.Contains("xl/styles.xml", names);

        var workbook = ReadEntry(zip, "xl/workbook.xml");
        Assert.Contains("报销明细", workbook);
        var sheet = ReadEntry(zip, "xl/worksheets/sheet1.xml");
        Assert.Contains("餐饮.pdf", sheet);
    }

    private static string ReadEntry(ZipArchive zip, string name)
    {
        var entry = zip.GetEntry(name)!;
        using var reader = new StreamReader(entry.Open(), Encoding.UTF8);
        return reader.ReadToEnd();
    }
}
