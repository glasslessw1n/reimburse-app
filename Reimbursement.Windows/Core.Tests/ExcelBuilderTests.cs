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
        Assert.Contains("1,753.00", xml); // 总计应为 553 + 1200 = 1,753（千分位写法）
        Assert.DoesNotContain("2,953.00", xml); // 不应重复计入酒店金额
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

    // MARK: - 样例版式（2026-11-09 附件 0910-1026.xlsx 定版，与 mac 版同口径）

    [Fact]
    public void SampleLayoutSkeleton()
    {
        var train = new BillInfo(BillType.TrainTicket, amount: 553, sourceFile: "火车票.pdf",
            fields: Fields(("departure_date", "2026-09-10"), ("origin_city", "重庆"), ("destination_city", "厦门")));
        train.TargetFilename = "0910 重庆-厦门 553.pdf";
        var bills = new List<BillInfo>
        {
            train,
            new(BillType.BoardingPass, amount: 0, sourceFile: "登机牌.pdf",
                fields: Fields(("departure_date", "2026-09-12"), ("origin_city", "厦门"), ("destination_city", "重庆"))),
            new(BillType.HotelFolio, amount: 1200, sourceFile: "水单.pdf",
                fields: Fields(("check_in_date", "2026-09-10"), ("check_out_date", "2026-09-12"), ("city", "厦门"))),
            new(BillType.Dining, amount: 100, sourceFile: "餐饮.pdf", fields: Fields(("issue_date", "2026-09-11"))),
        };
        var xml = ExcelBuilder.BuildSheet(bills, HomeCities);
        // 日期 MM/DD 写法；火车票与行程单同名「火车/机票」；登机牌也带路线
        Assert.Contains("09/10", xml);
        Assert.Contains("09/12", xml);
        Assert.Contains("火车/机票", xml);
        Assert.Contains("厦门-重庆", xml);
        // 备注列写整理后的目标文件名
        Assert.Contains("0910 重庆-厦门 553.pdf", xml);
        // 固定骨架：交通/酒店小计在；无滴滴也出汇总占位行；餐饮不出小计
        Assert.Contains("交通小计", xml);
        Assert.Contains("酒店小计", xml);
        Assert.Contains("共0段行程", xml);
        Assert.Contains("返回重庆: 09/12", xml);
        Assert.DoesNotContain("餐饮小计", xml);
        // 合计/总计：千分位金额 + 分类整数明细
        Assert.Contains("本段合计: ¥1,853.00", xml);
        Assert.Contains("报销总计: ¥1,853.00  (交通:553  酒店:1,200  滴滴:0  餐饮:100)", xml);
        // 版式元素：列宽、首行冻结、段标题/合计/总计三处合并
        Assert.Contains("<cols>", xml);
        Assert.Contains("state=\"frozen\"", xml);
        Assert.Contains("<mergeCells count=\"3\">", xml);
    }

    [Fact]
    public void LocalTelecomMonthLabel()
    {
        var bills = new List<BillInfo>
        {
            new(BillType.Telecom, amount: 197.3, sourceFile: "通信.pdf",
                fields: Fields(("issue_date", "2026-10-09"), ("month", "2026-10"))),
        };
        var xml = ExcelBuilder.BuildSheet(bills, HomeCities);
        Assert.Contains("【本地费用】", xml);
        Assert.Contains("10月", xml); // 通信费 B 列应为月份标签
        Assert.Contains("通信小计", xml);
    }
}
