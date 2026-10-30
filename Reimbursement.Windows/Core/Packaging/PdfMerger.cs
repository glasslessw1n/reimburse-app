using PdfSharp.Pdf;
using PdfSharp.Pdf.IO;
using Reimbursement.Core.Models;
using Reimbursement.Core.Storage;

namespace Reimbursement.Core.Packaging;

/// <summary>合并结果：总页数、成功合并的源文件名、跳过项（文件名：原因）。</summary>
public sealed record MergeResult(string OutputPath, int PageCount,
    IReadOnlyList<string> Merged, IReadOnlyList<string> Skipped);

/// <summary>
/// 简单合并 PDF（对应 toolkit 的 merge.py）：按排列规则把所有原件 PDF 逐页矢量合并为一份。
/// 排序与 merge.py 一致（行程：交通→酒店对→滴滴对→餐饮→其他；本地：通信→滴滴对→餐饮→其他），
/// 并修复 merge.py 的遗漏：自驾行程单与加油/通行费也纳入（置于行程最前）。
/// 非 PDF 原件（图片等）记入 Skipped（toolkit 靠 macOS sips 转 PDF，跨平台方案留待 App 层图像管线）。
/// </summary>
public static class PdfMerger
{
    private static string FirstMmdd(BillInfo b) =>
        b.DateMMDDs.FirstOrDefault(x => x.Length > 0) is { Length: > 0 } m ? BillInfo.Take(m, 4) : "9999";

    /// <summary>按合并顺序列出（分区名, 票据）。UI 可用它预览顺序。</summary>
    public static List<(string Section, BillInfo Bill)> BuildOrderedList(SessionManager session)
    {
        var ordered = new List<(string, BillInfo)>();
        foreach (var trip in session.Manifest.Trips)
            AppendContainer(ordered, trip.Bills, trip.Dirname);
        if (session.Manifest.Local.Count > 0)
            AppendContainer(ordered, session.Manifest.Local, "本地");
        return ordered;
    }

    private static void AppendContainer(List<(string Section, BillInfo Bill)> ordered,
        IReadOnlyList<BillInfo> bills, string section)
    {
        var transports = bills
            .Where(b => b.BillType is BillType.TrainTicket or BillType.FlightItinerary or BillType.BoardingPass)
            .OrderBy(b => FirstMmdd(b), StringComparer.Ordinal);
        var selfSheets = bills.Where(b => b.BillType == BillType.SelfDriveSheet);
        var selfInvoices = bills.Where(b => b.BillType == BillType.GasInvoice)
            .Concat(bills.Where(b => b.BillType == BillType.TollInvoice)
                .OrderBy(b => b.DidiLetter, StringComparer.Ordinal));
        var folios = bills.Where(b => b.BillType == BillType.HotelFolio)
            .OrderBy(b => b.DateRange.Start, StringComparer.Ordinal).ToList();
        var invoices = bills.Where(b => b.BillType == BillType.HotelInvoice)
            .OrderBy(b => b.DateRange.Start, StringComparer.Ordinal).ToList();
        var didiForms = bills.Where(b => b.BillType == BillType.DidiTrip)
            .OrderBy(b => b.DidiLetter.Length == 0 ? "ZZZ" : b.DidiLetter, StringComparer.Ordinal).ToList();
        var didiInvoices = bills.Where(b => b.BillType == BillType.DidiInvoice)
            .OrderBy(b => b.DidiLetter.Length == 0 ? "ZZZ" : b.DidiLetter, StringComparer.Ordinal).ToList();
        var dining = bills.Where(b => b.BillType == BillType.Dining)
            .OrderBy(b => FirstMmdd(b), StringComparer.Ordinal);
        var handled = new HashSet<BillInfo>(transports.Concat(selfSheets).Concat(selfInvoices)
            .Concat(folios).Concat(invoices).Concat(didiForms).Concat(didiInvoices).Concat(dining));
        var generic = bills.Where(b => !handled.Contains(b))
            .OrderBy(b => FirstMmdd(b), StringComparer.Ordinal);

        foreach (var b in selfSheets) ordered.Add((section, b));
        foreach (var b in selfInvoices) ordered.Add((section, b));
        foreach (var b in transports) ordered.Add((section, b));

        // 酒店：水单与其金额配对的发票相邻；未配对发票随后
        var usedInv = new HashSet<int>();
        foreach (var folio in folios)
        {
            ordered.Add((section, folio));
            for (var i = 0; i < invoices.Count; i++)
            {
                if (!usedInv.Contains(i) && Math.Abs(invoices[i].Amount - folio.Amount) < 0.01)
                {
                    usedInv.Add(i);
                    ordered.Add((section, invoices[i]));
                    break;
                }
            }
        }
        for (var i = 0; i < invoices.Count; i++)
            if (!usedInv.Contains(i)) ordered.Add((section, invoices[i]));

        // 滴滴：行程单与其字母的发票相邻（按字母序逐对）
        foreach (var form in didiForms)
        {
            ordered.Add((section, form));
            var inv = didiInvoices.FirstOrDefault(x =>
                x.DidiLetter.Length > 0 && x.DidiLetter == form.DidiLetter);
            if (inv != null) ordered.Add((section, inv));
        }
        foreach (var inv in didiInvoices)
        {
            if (!ordered.Any(o => ReferenceEquals(o.Bill, inv)))
                ordered.Add((section, inv));
        }

        foreach (var b in dining) ordered.Add((section, b));
        foreach (var b in generic) ordered.Add((section, b));
    }

    /// <summary>执行合并：按 BuildOrderedList 的顺序逐页导入 PDF 原件。</summary>
    public static MergeResult Merge(SessionManager session, string outputPath)
    {
        var originals = Path.Combine(session.RootDir, "originals");
        var ordered = BuildOrderedList(session);
        var merged = new List<string>();
        var skipped = new List<string>();

        using var output = new PdfDocument();
        foreach (var (_, bill) in ordered)
        {
            var path = Path.Combine(originals, bill.SourceFile);
            if (!File.Exists(path))
            {
                skipped.Add($"{bill.SourceFile}：原文件不存在");
                continue;
            }
            if (!string.Equals(Path.GetExtension(path), ".pdf", StringComparison.OrdinalIgnoreCase))
            {
                skipped.Add($"{bill.SourceFile}：非 PDF，合并跳过");
                continue;
            }
            try
            {
                using var src = PdfReader.Open(path, PdfDocumentOpenMode.Import);
                foreach (var page in src.Pages)
                    output.AddPage(page);
                merged.Add(bill.SourceFile);
            }
            catch (Exception e)
            {
                skipped.Add($"{bill.SourceFile}：合并失败（{e.Message}）");
            }
        }

        var dir = Path.GetDirectoryName(outputPath);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
        var pageCount = output.PageCount; // PDFsharp 保存后文档不可再读，先取页数
        output.Save(outputPath);
        return new MergeResult(outputPath, pageCount, merged, skipped);
    }
}
