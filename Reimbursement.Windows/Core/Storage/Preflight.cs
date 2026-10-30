using Reimbursement.Core.Models;

namespace Reimbursement.Core.Storage;

public enum PreflightSeverity { Info, Warning, Error }

/// <summary>一条提交前检查发现（对应 toolkit 诊断套件的现代化形态：以识别记录而非文件名为据）。</summary>
public sealed record PreflightIssue(PreflightSeverity Severity, string Category, string Message,
    string? BillUid, string? SourceFile);

/// <summary>
/// 提交前检查（打包前体检）：用金额+类型+日期交叉校验，
/// 比 toolkit 只比文件名字母的 check_pairing 更强。检查项：
/// 识别失败/需复核、金额缺失、水单缺发票、发票缺水单、滴滴单票缺边、行程未见返程、原文件缺失。
/// 未整理（无行程分组）时明确报"尚未整理"并对全部票据逐张预检，绝不空查误报无问题。
/// 本类绝不抛异常：字段一律 null 兜底，坏数据降级为检查项而不是崩溃。
/// </summary>
public static class Preflight
{
    // manifest JSON 可能把非空字符串字段反序列化成 null（旧版本/外部编辑），一律兜底
    private static string S(string? v) => v ?? "";

    public static List<PreflightIssue> Check(SessionManager session, IReadOnlySet<string> homeCities)
    {
        var issues = new List<PreflightIssue>();
        var originals = Path.Combine(session.RootDir, "originals");

        void CheckContainer(IReadOnlyList<BillInfo> bills, string sectionName, bool isTrip)
        {
            foreach (var b in bills)
            {
                if (S(b.Error).Length > 0)
                    issues.Add(new(PreflightSeverity.Error, "识别失败",
                        $"{b.SourceFile}：{b.Error}", b.Uid, b.SourceFile));
                else if (b.NeedsReview)
                    issues.Add(new(PreflightSeverity.Warning, "需人工复核",
                        $"{b.SourceFile}：{S(b.ReviewReason)}", b.Uid, b.SourceFile));

                if (BillTypeFields.Spec(b.BillType).Required.Contains("amount") && b.Amount <= 0)
                    issues.Add(new(PreflightSeverity.Warning, "金额缺失",
                        $"{b.SourceFile}（{b.BillType.DisplayName()}）金额为空或为 0", b.Uid, b.SourceFile));

                if (!File.Exists(Path.Combine(originals, b.SourceFile)))
                    issues.Add(new(PreflightSeverity.Error, "原文件缺失",
                        $"{b.SourceFile} 在 originals 中不存在", b.Uid, b.SourceFile));
            }

            // 酒店配对完整性（金额 <0.01 视为同住）
            var folios = bills.Where(b => b.BillType == BillType.HotelFolio).ToList();
            var invoices = bills.Where(b => b.BillType == BillType.HotelInvoice).ToList();
            foreach (var f in folios)
            {
                if (!invoices.Any(i => Math.Abs(i.Amount - f.Amount) < 0.01))
                    issues.Add(new(PreflightSeverity.Warning, "水单缺发票",
                        $"{sectionName}：{f.SourceFile}（¥{f.Amount:0.##}）没有金额相同的酒店发票，住宿费可能无法报销",
                        f.Uid, f.SourceFile));
            }
            foreach (var i in invoices)
            {
                if (!folios.Any(f => Math.Abs(f.Amount - i.Amount) < 0.01))
                    issues.Add(new(PreflightSeverity.Info, "发票缺水单",
                        $"{sectionName}：{i.SourceFile}（¥{i.Amount:0.##}）没有金额相同的水单",
                        i.Uid, i.SourceFile));
            }

            // 滴滴配对完整性
            var forms = bills.Where(b => b.BillType == BillType.DidiTrip).ToList();
            var dinvs = bills.Where(b => b.BillType == BillType.DidiInvoice).ToList();
            foreach (var f in forms)
            {
                if (!dinvs.Any(i => Math.Abs(i.Amount - f.Amount) < 0.01))
                    issues.Add(new(PreflightSeverity.Warning, "滴滴缺发票",
                        $"{sectionName}：行程单 {f.SourceFile}（¥{f.Amount:0.##}）没有金额相同的滴滴发票",
                        f.Uid, f.SourceFile));
            }
            foreach (var i in dinvs)
            {
                if (!forms.Any(f => Math.Abs(f.Amount - i.Amount) < 0.01))
                    issues.Add(new(PreflightSeverity.Warning, "滴滴缺行程单",
                        $"{sectionName}：发票 {i.SourceFile}（¥{i.Amount:0.##}）没有金额相同的行程单",
                        i.Uid, i.SourceFile));
            }

            // 行程闭合：有去程锚点却没有任何一张锚点的到达城市是常驻地
            if (isTrip && homeCities.Count > 0)
            {
                var anchors = bills.Where(b => b.BillType is BillType.TrainTicket or BillType.FlightItinerary
                    or BillType.BoardingPass or BillType.SelfDriveSheet).ToList();
                if (anchors.Count > 0 && !anchors.Any(a =>
                        homeCities.Contains(S(a.ToCity).Trim().ToLowerInvariant())))
                {
                    issues.Add(new(PreflightSeverity.Warning, "行程未见返程",
                        $"{sectionName}：没有任何票据的到达城市是常驻地，可能缺返程票据", null, null));
                }
            }
        }

        foreach (var trip in session.Manifest.Trips)
            CheckContainer(trip.Bills, trip.Dirname, isTrip: true);
        if (session.Manifest.Local.Count > 0)
            CheckContainer(session.Manifest.Local, "本地", isTrip: false);

        // 未整理状态：行程分组为空但已有识别记录——只查行程等于空查、会误报"无问题"。
        // 明确报出未整理，并对全部票据照常做逐张检查，让用户一次看到所有问题。
        if (session.Manifest.Trips.Count == 0 && session.Manifest.Local.Count == 0
            && session.Manifest.Bills.Count > 0)
        {
            issues.Insert(0, new PreflightIssue(PreflightSeverity.Error, "尚未整理",
                $"已识别 {session.Manifest.Bills.Count} 张票据，但还没有点击「整理」生成行程分组；" +
                "提交前检查与打包都需要先整理。以下为逐张票据的预检结果。", null, null));
            CheckContainer(session.Manifest.Bills, "全部票据", isTrip: false);
        }

        return issues;
    }
}
