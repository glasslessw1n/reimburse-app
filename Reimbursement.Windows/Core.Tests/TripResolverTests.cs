using Reimbursement.Core.Models;
using Reimbursement.Core.Trips;
using Xunit;

namespace Reimbursement.Core.Tests;

/// <summary>
/// TripResolver 行程切分算法测试（由 Swift TripResolverTests 逐条翻译）。
/// 用例原则：每个聚焦一个决策分支（开新/闭合/拼接），只构造 BillInfo 喂入，不用真实 LLM 输出。
/// </summary>
public class TripResolverTests
{
    private static readonly HashSet<string> HomeCities = new() { "重庆", "成都" };

    private static (List<TripGroup> Trips, List<BillInfo> Local) Resolve(params BillInfo[] bills) =>
        TripResolver.AssignTrips(bills, HomeCities);

    /// <summary>构造 anchor BillInfo（与 Swift 测试 helper 同构：date 同时写入 departure/check_in/issue 三个字段）。</summary>
    private static BillInfo Anchor(BillType type, string from = "", string to = "",
        string date = "", string endDate = "", double amount = 0, List<string>? cities = null)
    {
        var fields = new Dictionary<string, string?>();
        if (date.Length > 0)
        {
            fields["departure_date"] = date;
            fields["check_in_date"] = date;
            fields["issue_date"] = date;
        }
        if (endDate.Length > 0) fields["check_out_date"] = endDate;
        if (from.Length > 0) fields["origin_city"] = from;
        if (to.Length > 0) fields["destination_city"] = to;
        var info = new BillInfo(type, amount, "test.pdf", fields);
        info.Cities = cities ?? new[] { from, to }.Where(c => c.Length > 0).ToList();
        return info;
    }

    private static string Dump(List<TripGroup> groups) => string.Join("\n",
        groups.Select((g, i) =>
            $"Trip[{i}] {g.Key} cities=[{string.Join(",", g.Cities)}] bills=[{string.Join(", ", g.Bills.Select(b => b.BillType.ToRaw()))}]"));

    /// <summary>1. 最简 happy path：重庆→厦门登机牌 + 厦门酒店 + 厦门→重庆登机牌 = 1 段 3 张。</summary>
    [Fact]
    public void SingleTripHomeDepartureReturn()
    {
        var r = Resolve(
            Anchor(BillType.BoardingPass, "重庆", "厦门", "2026-09-10"),
            Anchor(BillType.HotelFolio, "厦门", "厦门", "2026-09-10", "2026-09-12"),
            Anchor(BillType.BoardingPass, "厦门", "重庆", "2026-09-12"));
        Assert.True(r.Trips.Count == 1, $"应只切出 1 段行程\n{Dump(r.Trips)}");
        Assert.Equal(3, r.Trips[0].Bills.Count);
        Assert.Equal("0910", r.Trips[0].FirstMMDD);
        Assert.Equal("0912", r.Trips[0].LastMMDD);
        Assert.DoesNotContain(r.Trips[0].Cities, c => c.ToLowerInvariant() == "重庆");
        Assert.Contains("厦门", r.Trips[0].Cities);
    }

    /// <summary>2. 0917-0918 福州住宿发票应就近归到下一个行程（0922 起），而不是上一段。</summary>
    [Fact]
    public void HotelInvoiceAttachesToFollowingTrip()
    {
        var r = Resolve(
            Anchor(BillType.BoardingPass, "重庆", "厦门", "2026-09-10"),
            Anchor(BillType.BoardingPass, "厦门", "重庆", "2026-09-12"),
            Anchor(BillType.HotelInvoice, "福州", "福州", "2026-09-18"),
            Anchor(BillType.BoardingPass, "重庆", "福州", "2026-09-22"),
            Anchor(BillType.BoardingPass, "福州", "重庆", "2026-09-24"));
        Assert.True(r.Trips.Count == 2, $"应切出 2 段行程\n{Dump(r.Trips)}");
        Assert.Equal(2, r.Trips[0].Bills.Count(b => b.BillType == BillType.BoardingPass));
        Assert.Equal("0912", r.Trips[0].LastMMDD);
        var t2 = r.Trips[1];
        Assert.Contains(t2.Bills, b => b.BillType == BillType.HotelInvoice && b.F("issue_date") == "2026-09-18");
        Assert.Equal("0922", t2.FirstMMDD);
        Assert.Equal("0924", t2.LastMMDD);
    }

    /// <summary>3. trip 闭合后，非 home 出发且城市命中的 anchor 归回原 trip（封闭后吸收补件）。</summary>
    [Fact]
    public void ClosedTripAbsorbsMissingReturn()
    {
        var r = Resolve(
            Anchor(BillType.BoardingPass, "重庆", "厦门", "2026-09-10"),
            Anchor(BillType.BoardingPass, "厦门", "重庆", "2026-09-12"),
            Anchor(BillType.TrainTicket, "厦门", "福州", "2026-09-13"));
        Assert.True(r.Trips.Count == 1, $"应只切出 1 段\n{Dump(r.Trips)}");
        Assert.Equal(3, r.Trips[0].Bills.Count);
        Assert.Equal("0913", r.Trips[0].LastMMDD);
    }

    /// <summary>4. trip 闭合后，home 出发的 anchor 开新 trip。</summary>
    [Fact]
    public void ClosedTripNewDepartureStartsNewTrip()
    {
        var r = Resolve(
            Anchor(BillType.BoardingPass, "重庆", "厦门", "2026-09-10"),
            Anchor(BillType.BoardingPass, "厦门", "重庆", "2026-09-12"),
            Anchor(BillType.BoardingPass, "重庆", "北京", "2026-09-20"),
            Anchor(BillType.BoardingPass, "北京", "重庆", "2026-09-22"));
        Assert.Equal(2, r.Trips.Count);
        Assert.Equal(("0910", "0912"), (r.Trips[0].FirstMMDD, r.Trips[0].LastMMDD));
        Assert.Equal(("0920", "0922"), (r.Trips[1].FirstMMDD, r.Trips[1].LastMMDD));
    }

    /// <summary>5. trip 未闭合时 home 出发（漏返程）拼到当前 trip。</summary>
    [Fact]
    public void UnclosedTripNewDepartureMerges()
    {
        var r = Resolve(
            Anchor(BillType.BoardingPass, "重庆", "厦门", "2026-09-10"),
            Anchor(BillType.TrainTicket, "重庆", "福州", "2026-09-15"));
        Assert.Single(r.Trips);
        Assert.Equal(2, r.Trips[0].Bills.Count);
    }

    /// <summary>6. 内部 X→Y 拼当前 trip；home 到达闭合。</summary>
    [Fact]
    public void InternalAnchorAttachesToCurrentTrip()
    {
        var r = Resolve(
            Anchor(BillType.BoardingPass, "重庆", "厦门", "2026-09-10"),
            Anchor(BillType.TrainTicket, "厦门", "福州", "2026-09-11"),
            Anchor(BillType.BoardingPass, "福州", "重庆", "2026-09-13"));
        Assert.Single(r.Trips);
        Assert.Equal(3, r.Trips[0].Bills.Count);
        Assert.Equal("0913", r.Trips[0].LastMMDD);
    }

    /// <summary>6b. 新段开始后出现的内部跳转归新段，不回吸到已闭合的旧段。</summary>
    [Fact]
    public void ClosedTripDoesNotAbsorbOrphanInternalAnchor()
    {
        var r = Resolve(
            Anchor(BillType.BoardingPass, "重庆", "厦门", "2026-09-10"),
            Anchor(BillType.BoardingPass, "厦门", "重庆", "2026-09-12"),
            Anchor(BillType.BoardingPass, "重庆", "广州", "2026-09-15"),
            Anchor(BillType.TrainTicket, "广州", "深圳", "2026-09-15"));
        Assert.Equal(2, r.Trips.Count);
        Assert.Equal("0912", r.Trips[0].LastMMDD);
        Assert.Equal(2, r.Trips[1].Bills.Count);
    }

    /// <summary>7. 酒店水单 non-anchor 就近归段，且不影响段的 first/last（由 anchor 决定）。</summary>
    [Fact]
    public void HotelFolioCheckOutAttachesToTrip()
    {
        var r = Resolve(
            Anchor(BillType.BoardingPass, "重庆", "厦门", "2026-09-10"),
            Anchor(BillType.HotelFolio, "厦门", "厦门", "2026-09-10", "2026-09-13"),
            Anchor(BillType.BoardingPass, "厦门", "重庆", "2026-09-11"));
        Assert.Single(r.Trips);
        Assert.Equal("0911", r.Trips[0].LastMMDD);
        Assert.Contains(r.Trips[0].Bills, b => b.BillType == BillType.HotelFolio);
    }

    /// <summary>8. non-anchor 按日期就近 ≤7 天归段。</summary>
    [Fact]
    public void NonAnchorAttachesByDate()
    {
        var r = Resolve(
            Anchor(BillType.BoardingPass, "重庆", "厦门", "2026-09-10"),
            Anchor(BillType.BoardingPass, "厦门", "重庆", "2026-09-12"),
            Anchor(BillType.Dining, date: "2026-09-15"));
        Assert.Single(r.Trips);
        Assert.Contains(r.Trips[0].Bills, b => b.BillType == BillType.Dining);
    }

    /// <summary>9. 距离 >7 天的 non-anchor 落本地。</summary>
    [Fact]
    public void NonAnchorTooFarGoesToLocal()
    {
        var r = Resolve(
            Anchor(BillType.BoardingPass, "重庆", "厦门", "2026-09-10"),
            Anchor(BillType.BoardingPass, "厦门", "重庆", "2026-09-12"),
            Anchor(BillType.Dining, date: "2026-09-30"));
        Assert.Single(r.Trips);
        Assert.Single(r.Local);
        Assert.Equal(BillType.Dining, r.Local[0].BillType);
    }

    /// <summary>10. 空输入 → 0 trips。</summary>
    [Fact]
    public void EmptyInput()
    {
        var r = Resolve();
        Assert.Empty(r.Trips);
        Assert.Empty(r.Local);
    }

    /// <summary>11. 全是 non-anchor → 全部本地。</summary>
    [Fact]
    public void AllNonAnchors()
    {
        var r = Resolve(
            Anchor(BillType.Dining, date: "2026-09-10"),
            Anchor(BillType.Other, date: "2026-09-15"));
        Assert.Empty(r.Trips);
        Assert.Equal(2, r.Local.Count);
    }

    /// <summary>12. 决策分支全覆盖：三段往返。</summary>
    [Fact]
    public void DecisionMatrixCoverage()
    {
        var r = Resolve(
            Anchor(BillType.BoardingPass, "重庆", "厦门", "2026-09-10"),
            Anchor(BillType.TrainTicket, "厦门", "福州", "2026-09-11"),
            Anchor(BillType.BoardingPass, "福州", "重庆", "2026-09-13"),
            Anchor(BillType.BoardingPass, "重庆", "北京", "2026-09-20"),
            Anchor(BillType.TrainTicket, "北京", "天津", "2026-09-21"),
            Anchor(BillType.BoardingPass, "天津", "重庆", "2026-09-22"),
            Anchor(BillType.TrainTicket, "重庆", "上海", "2026-09-25"),
            Anchor(BillType.BoardingPass, "上海", "重庆", "2026-09-26"));
        Assert.True(r.Trips.Count == 3, $"应切出 3 段行程\n{Dump(r.Trips)}");
        Assert.Equal(("0910", "0913", 3), (r.Trips[0].FirstMMDD, r.Trips[0].LastMMDD, r.Trips[0].Bills.Count));
        Assert.Equal(("0920", "0922", 3), (r.Trips[1].FirstMMDD, r.Trips[1].LastMMDD, r.Trips[1].Bills.Count));
        Assert.Equal(("0925", "0926", 2), (r.Trips[2].FirstMMDD, r.Trips[2].LastMMDD, r.Trips[2].Bills.Count));
    }

    /// <summary>13. 酒店水单+发票配对归同一 trip。</summary>
    [Fact]
    public void HotelInvoiceAndFolioSameTrip()
    {
        var r = Resolve(
            Anchor(BillType.BoardingPass, "重庆", "厦门", "2026-09-10"),
            Anchor(BillType.HotelFolio, "厦门", "厦门", "2026-09-10", "2026-09-12"),
            Anchor(BillType.HotelInvoice, "厦门", "厦门", "2026-09-12"),
            Anchor(BillType.BoardingPass, "厦门", "重庆", "2026-09-12"));
        Assert.Single(r.Trips);
        Assert.Equal(4, r.Trips[0].Bills.Count);
    }

    /// <summary>14. MmddFromDateString 工具方法。</summary>
    [Fact]
    public void MmddFromDateString()
    {
        Assert.Equal("0910", TripResolver.MmddFromDateString("2026-09-10"));
        Assert.Equal("0910", TripResolver.MmddFromDateString("2026-09-10T10:30:00"));
        Assert.Equal("", TripResolver.MmddFromDateString(""));
        Assert.Equal("", TripResolver.MmddFromDateString("xxx"));
    }

    /// <summary>15. AbsDateDiff 工具方法。</summary>
    [Fact]
    public void AbsDateDiff()
    {
        Assert.Equal(9, TripResolver.AbsDateDiff("0901", "0910"));
        Assert.Equal(9, TripResolver.AbsDateDiff("0910", "0901"));
        Assert.Equal(30, TripResolver.AbsDateDiff("0910", "1010"));
    }

    /// <summary>16. 跨年日期差：12 月底 ↔ 1 月初应是小差值。</summary>
    [Fact]
    public void AbsDateDiffCrossYear()
    {
        Assert.True(TripResolver.AbsDateDiff("1229", "0103") <= 10);
        Assert.True(TripResolver.AbsDateDiff("0103", "1229") <= 10);
    }

    /// <summary>17. 跨年行程合并为一段且 first/last 顺序正确。</summary>
    [Fact]
    public void CrossYearTripOrdering()
    {
        var r = Resolve(
            Anchor(BillType.BoardingPass, "重庆", "厦门", "2025-12-30"),
            Anchor(BillType.BoardingPass, "厦门", "重庆", "2026-01-02"));
        Assert.True(r.Trips.Count == 1, $"跨年往返应合并为一段\n{Dump(r.Trips)}");
        Assert.Equal("1230", r.Trips[0].FirstMMDD);
        Assert.Equal("0102", r.Trips[0].LastMMDD);
    }

    /// <summary>18. FullDateDiff 跨年精确天数。</summary>
    [Fact]
    public void FullDateDiffCrossYear()
    {
        Assert.Equal(5, TripResolver.FullDateDiff("2025-12-29", "2026-01-03"));
        Assert.Equal(5, TripResolver.FullDateDiff("2026-01-03", "2025-12-29"));
        Assert.Equal(0, TripResolver.FullDateDiff("2026-01-01", "2026-01-01"));
    }

    // MARK: - 驻地优先归属 + 边界日例外 + 手动归类（2026-11-09，与 mac 版同口径）

    private static BillInfo[] WanzhouAnchors() => new[]
    {
        Anchor(BillType.TrainTicket, from: "重庆", to: "万州", date: "2026-10-20", amount: 100),
        Anchor(BillType.TrainTicket, from: "万州", to: "重庆", date: "2026-10-22", amount: 100),
    };

    private static BillInfo DiningAt(string city, string date, double amount = 76) =>
        new(BillType.Dining, amount, "dd.pdf", new Dictionary<string, string?>
        {
            ["issue_date"] = date,
            ["city"] = city,
        });

    /// <summary>驻地滴滴在行程窗口内（中间日）→ 本地，不被日期吸进万州行程。</summary>
    [Fact]
    public void HomeDidiTripGoesLocal()
    {
        var bills = WanzhouAnchors().Append(
            Anchor(BillType.DidiTrip, from: "重庆", to: "重庆", date: "2026-10-21", amount: 35)).ToArray();
        var r = Resolve(bills);
        Assert.Single(r.Trips);
        Assert.Contains(r.Local, b => b.BillType == BillType.DidiTrip);
        Assert.DoesNotContain(r.Trips[0].Bills, b => b.BillType == BillType.DidiTrip);
    }

    /// <summary>边界日例外：出发日的驻地滴滴是去车站的接驳 → 归行程。</summary>
    [Fact]
    public void HomeDidiOnDepartureDayJoinsTrip()
    {
        var bills = WanzhouAnchors().Append(
            Anchor(BillType.DidiTrip, from: "重庆", to: "重庆", date: "2026-10-20", amount: 42)).ToArray();
        var r = Resolve(bills);
        Assert.Contains(r.Trips[0].Bills, b => b.BillType == BillType.DidiTrip);
        Assert.DoesNotContain(r.Local, b => b.BillType == BillType.DidiTrip);
    }

    /// <summary>边界日例外：返回日的驻地滴滴与发票 → 归行程。</summary>
    [Fact]
    public void HomeDidiOnReturnDayJoinsTrip()
    {
        var bills = WanzhouAnchors()
            .Append(Anchor(BillType.DidiTrip, from: "重庆", to: "重庆", date: "2026-10-22", amount: 38))
            .Append(Anchor(BillType.DidiInvoice, from: "重庆", to: "重庆", date: "2026-10-22", amount: 38))
            .ToArray();
        var r = Resolve(bills);
        Assert.Contains(r.Trips[0].Bills, b => b.BillType == BillType.DidiTrip);
        Assert.Contains(r.Trips[0].Bills, b => b.BillType == BillType.DidiInvoice);
    }

    /// <summary>边界日例外仅限滴滴：出发日当天在驻地开具的餐饮仍归本地。</summary>
    [Fact]
    public void HomeDiningOnDepartureDayStaysLocal()
    {
        var bills = WanzhouAnchors().Append(DiningAt("重庆", "2026-10-20")).ToArray();
        var r = Resolve(bills);
        Assert.Contains(r.Local, b => b.SourceFile == "dd.pdf");
    }

    /// <summary>万州当地滴滴（城市为万州）→ 归万州行程；万州是独立地名，不算驻地。</summary>
    [Fact]
    public void AwayDidiTripStaysInTrip()
    {
        var bills = WanzhouAnchors().Append(
            Anchor(BillType.DidiTrip, from: "万州", to: "万州", date: "2026-10-21", amount: 30)).ToArray();
        var r = Resolve(bills);
        Assert.Contains(r.Trips[0].Bills, b => b.BillType == BillType.DidiTrip);
        Assert.DoesNotContain(r.Local, b => b.BillType == BillType.DidiTrip);
    }

    /// <summary>餐饮按开具地归属：驻地开具 → 本地。</summary>
    [Fact]
    public void HomeDiningGoesLocal()
    {
        var bills = WanzhouAnchors().Append(DiningAt("重庆", "2026-10-21")).ToArray();
        var r = Resolve(bills);
        Assert.Contains(r.Local, b => b.SourceFile == "dd.pdf");
    }

    /// <summary>餐饮按开具地归属：行程城市开具 → 行程内。</summary>
    [Fact]
    public void TripCityDiningStaysInTrip()
    {
        var bills = WanzhouAnchors().Append(DiningAt("万州", "2026-10-21")).ToArray();
        var r = Resolve(bills);
        Assert.Contains(r.Trips[0].Bills, b => b.SourceFile == "dd.pdf");
    }

    /// <summary>餐饮按开具地归属：第三地开具（窗口内）→ 按日期归行程（团队异地聚餐）。</summary>
    [Fact]
    public void ThirdCityDiningStaysInTrip()
    {
        var bills = WanzhouAnchors().Append(DiningAt("北京", "2026-10-21")).ToArray();
        var r = Resolve(bills);
        Assert.Contains(r.Trips[0].Bills, b => b.SourceFile == "dd.pdf");
    }

    /// <summary>无城市的餐饮回落日期归属；「重庆市」规范化为驻地。</summary>
    [Fact]
    public void DiningWithoutCityFallsBackToDate()
    {
        var bills = WanzhouAnchors().Append(
            new BillInfo(BillType.Dining, 76, "dd.pdf", new Dictionary<string, string?>
            {
                ["issue_date"] = "2026-10-21",
            })).ToArray();
        var r = Resolve(bills);
        Assert.Contains(r.Trips[0].Bills, b => b.SourceFile == "dd.pdf");
    }

    [Fact]
    public void HomeCityWithShiSuffixNormalized()
    {
        var bills = WanzhouAnchors().Append(
            Anchor(BillType.DidiTrip, from: "重庆市", to: "重庆市", date: "2026-10-21", amount: 35)).ToArray();
        var r = Resolve(bills);
        Assert.Contains(r.Local, b => b.BillType == BillType.DidiTrip);
    }

    /// <summary>手动归类：行程内的票据 override 到「本地」。</summary>
    [Fact]
    public void GroupOverrideMovesBillToLocal()
    {
        var dining = DiningAt("万州", "2026-10-21");
        dining.GroupOverride = "本地";
        var bills = WanzhouAnchors().Append(dining).ToArray();
        var r = Resolve(bills);
        Assert.Contains(r.Local, b => b.SourceFile == "dd.pdf");
        Assert.DoesNotContain(r.Trips[0].Bills, b => b.SourceFile == "dd.pdf");
    }

    /// <summary>手动归类：本地票据 override 到指定行程（目标用行程 dirname）。</summary>
    [Fact]
    public void GroupOverrideMovesLocalBillToTrip()
    {
        var probe = Resolve(WanzhouAnchors());
        var dirname = probe.Trips[0].Dirname;
        var dining = DiningAt("重庆", "2026-10-21");
        dining.GroupOverride = dirname;
        var bills = WanzhouAnchors().Append(dining).ToArray();
        var r = Resolve(bills);
        Assert.Contains(r.Trips[0].Bills, b => b.SourceFile == "dd.pdf");
        Assert.DoesNotContain(r.Local, b => b.SourceFile == "dd.pdf");
    }

    /// <summary>手动归类：目标行程不存在（已改名）→ 回落自动归属，不丢票据。</summary>
    [Fact]
    public void GroupOverrideToMissingTripFallsBack()
    {
        var dining = DiningAt("万州", "2026-10-21");
        dining.GroupOverride = "0101-0102 不存在的行程";
        var bills = WanzhouAnchors().Append(dining).ToArray();
        var r = Resolve(bills);
        Assert.Contains(r.Trips[0].Bills, b => b.SourceFile == "dd.pdf");
    }
}
