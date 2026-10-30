using Reimbursement.Core.Models;

namespace Reimbursement.Core.Trips;

/// <summary>
/// 行程分组算法（对应 Swift TripResolver / Python assign_trip）：以"常驻地"为切分依据——
/// 从常驻地出发 → 回到常驻地为一段行程。
/// 1. anchor（交通票+自驾单）按 fullDatePool 最早日期排序后扫一遍做切分决策；
/// 2. non-anchor 按所有相关完整日期就近归段（≤7 天），否则落「本地」；
/// 3. 行程目录城市过滤掉常驻地。
/// 注意：homeCities 集合应已是 trim+小写后的形式（IsHomeCity 只归一化待查城市，与 Swift 版一致）。
/// </summary>
public static class TripResolver
{
    /// <summary>
    /// 锚点票据（能确定行程归属）。酒店水单/发票不算 anchor——它们只有 city 没有 from/to，
    /// 当 anchor 会把就近的酒店发票强行归段并污染段的 last 日期。
    /// </summary>
    private static readonly HashSet<BillType> AnchorTypes = new()
    {
        BillType.TrainTicket, BillType.FlightItinerary, BillType.BoardingPass, BillType.SelfDriveSheet,
    };

    public static (List<TripGroup> Trips, List<BillInfo> Local) AssignTrips(
        IReadOnlyList<BillInfo> bills, IReadOnlySet<string> homeCities)
    {
        var anchors = new List<BillInfo>();
        var nonAnchors = new List<BillInfo>();
        foreach (var b in bills)
            (AnchorTypes.Contains(b.BillType) ? anchors : nonAnchors).Add(b);

        // 按「所有相关完整日期」的最早者稳定排序（跨年正确）
        anchors = anchors.OrderBy(a => FullDatePool(a).FirstOrDefault() ?? "", StringComparer.Ordinal).ToList();

        var groups = new List<TripGroup>();
        var groupFirst = new List<string>(); // 每段完整起始日期 yyyy-MM-dd
        var groupLast = new List<string>();  // 每段完整结束日期 yyyy-MM-dd
        int? currentIdx = null;
        var currentTripClosed = false;
        var undatedAnchors = new List<BillInfo>();

        foreach (var anchor in anchors)
        {
            var pool = FullDatePool(anchor);
            var aFirstFull = pool.FirstOrDefault() ?? "";
            if (aFirstFull.Length == 0)
            {
                // 无日期的交通票无法参与切分，但保留到「本地」，避免整张消失
                undatedAnchors.Add(anchor);
                continue;
            }
            var aLastFull = pool.Last() ;

            var isHomeDeparture = IsHomeCity(anchor.FromCity, homeCities);
            var isHomeArrival = IsHomeCity(anchor.ToCity, homeCities);

            // 决策（与 Swift 版同构的显式分支，避免链式短路差异）：
            //   - 第一个 anchor → 开新 trip
            //   - 当前 trip 未闭合 + to=home → 闭合当前 trip 并归入
            //   - from=home → 已闭合则开新 trip；未闭合是漏返程补充，拼到当前 trip
            //   - 已闭合且非 home 起讫 → 城市命中任一已有 trip 则归那段并重新激活，否则开新 trip
            //   - 未闭合且非 home 起讫 → 归当前 trip
            bool startNew;
            if (currentIdx == null)
            {
                startNew = true;
            }
            else if (isHomeArrival && !currentTripClosed)
            {
                currentTripClosed = true;
                startNew = false;
            }
            else if (isHomeDeparture)
            {
                startNew = currentTripClosed;
            }
            else if (currentTripClosed)
            {
                int? matchedIdx = null;
                for (var i = 0; i < groups.Count; i++)
                {
                    var tripCities = new HashSet<string>(
                        groups[i].Cities.Select(c => c.Trim().ToLowerInvariant()));
                    if (anchor.FromCity.Length > 0 && matchedIdx == null &&
                        tripCities.Contains(anchor.FromCity.Trim().ToLowerInvariant()))
                        matchedIdx = i;
                    if (anchor.ToCity.Length > 0 && matchedIdx == null &&
                        tripCities.Contains(anchor.ToCity.Trim().ToLowerInvariant()))
                        matchedIdx = i;
                }
                if (matchedIdx is { } mIdx)
                {
                    currentIdx = mIdx;
                    currentTripClosed = false; // 重新激活（接受后续 anchor）
                    startNew = false;
                }
                else
                {
                    startNew = true;
                }
            }
            else
            {
                startNew = false;
            }

            if (startNew)
            {
                groups.Add(new TripGroup(
                    key: $"{MmddFromDateString(aFirstFull)}-{MmddFromDateString(aLastFull)}",
                    firstMMDD: MmddFromDateString(aFirstFull),
                    lastMMDD: MmddFromDateString(aLastFull)));
                groupFirst.Add(aFirstFull);
                groupLast.Add(aLastFull);
                currentIdx = groups.Count - 1;
                currentTripClosed = false;
            }

            if (currentIdx is { } idx)
            {
                // 用完整日期比较（跨年正确）扩展 trip 的 first/last
                if (string.CompareOrdinal(aFirstFull, groupFirst[idx]) < 0)
                {
                    groupFirst[idx] = aFirstFull;
                    groups[idx].FirstMMDD = MmddFromDateString(aFirstFull);
                }
                if (string.CompareOrdinal(aLastFull, groupLast[idx]) > 0)
                {
                    groupLast[idx] = aLastFull;
                    groups[idx].LastMMDD = MmddFromDateString(aLastFull);
                }
                // 加 city（过滤常驻地）
                foreach (var c in anchor.Cities)
                {
                    if (!groups[idx].Cities.Contains(c) && !IsHomeCity(c, homeCities))
                        groups[idx].Cities.Add(c);
                }
                var a = anchor.Clone();
                a.TargetSubdir = groups[idx].Dirname;
                groups[idx].Bills.Add(a);
            }
        }

        // non-anchor：按「所有相关完整日期」就近归到 trip（≤7 天）
        var local = new List<BillInfo>();
        foreach (var non in nonAnchors)
        {
            var pool = FullDatePool(non);
            if (pool.Count == 0)
            {
                local.Add(non);
                continue;
            }
            var firstDate = pool[0];
            int? bestIdx = null;
            var bestDiff = int.MaxValue;
            for (var i = 0; i < groups.Count; i++)
            {
                var d = Math.Min(FullDateDiff(firstDate, groupFirst[i]), FullDateDiff(firstDate, groupLast[i]));
                if (d < bestDiff) { bestIdx = i; bestDiff = d; }
            }
            if (bestIdx is { } bIdx && bestDiff <= 7)
            {
                var b = non.Clone();
                b.TargetSubdir = groups[bIdx].Dirname;
                groups[bIdx].Bills.Add(b);
            }
            else
            {
                var b = non.Clone();
                b.TargetSubdir = "本地";
                local.Add(b);
            }
        }

        // 无日期的 anchor 落到「本地」，保证不丢
        foreach (var u0 in undatedAnchors)
        {
            var u = u0.Clone();
            u.TargetSubdir = "本地";
            local.Add(u);
        }

        // 重新刷一遍所有 bill 的 TargetSubdir（分组扩展后 dirname 可能变）
        foreach (var g in groups)
        {
            var dirname = g.Dirname;
            foreach (var b in g.Bills) b.TargetSubdir = dirname;
        }

        return (groups, local);
    }

    // MARK: - 通用工具

    /// <summary>
    /// 该 bill 涉及的所有完整日期（yyyy-MM-dd，含年份，跨年排序/合并正确）：
    /// dateRange + fields 里的日期字段，去重排序。
    /// </summary>
    public static List<string> FullDatePool(BillInfo bill)
    {
        var pool = new List<string>();
        void Add(string d)
        {
            if (d.Length < 10) return;
            var s = d[..10];
            if (!pool.Contains(s)) pool.Add(s);
        }
        Add(bill.DateRange.Start);
        Add(bill.DateRange.End);
        foreach (var k in new[] { "departure_date", "check_in_date", "check_out_date", "issue_date" })
        {
            if (bill.F(k) is { Length: >= 10 } v) Add(v);
        }
        pool.Sort(StringComparer.Ordinal);
        return pool;
    }

    /// <summary>两个完整日期（yyyy-MM-dd）之间的天数差（跨年精确；解析失败返回 int.MaxValue）。</summary>
    public static int FullDateDiff(string a, string b)
    {
        if (!TryParseFullDate(a, out var da) || !TryParseFullDate(b, out var db))
            return int.MaxValue;
        return Math.Abs(da.DayNumber - db.DayNumber);
    }

    private static bool TryParseFullDate(string s, out DateOnly result)
    {
        result = default;
        if (s.Length < 10) return false;
        if (!int.TryParse(s.AsSpan(0, 4), out var y) ||
            !int.TryParse(s.AsSpan(5, 2), out var m) ||
            !int.TryParse(s.AsSpan(8, 2), out var d))
            return false;
        try { result = new DateOnly(y, m, d); return true; }
        catch (ArgumentOutOfRangeException) { return false; }
    }

    private static bool IsHomeCity(string city, IReadOnlySet<string> home) =>
        home.Contains(city.Trim().ToLowerInvariant());

    /// <summary>YYYY-MM-DD[THH:mm:ss] → MMDD（例：2026-09-10 → 0910）。</summary>
    public static string MmddFromDateString(string s)
    {
        if (s.Length < 10) return "";
        return s.Substring(5, 5).Replace("-", "");
    }

    /// <summary>两个 MMDD 之间的天数差（同年内；跨年时用 ±1 年组合取最小；解析失败返回 99）。</summary>
    public static int AbsDateDiff(string mmdd1, string mmdd2)
    {
        if (mmdd1.Length < 4 || mmdd2.Length < 4 ||
            !int.TryParse(mmdd1.AsSpan(0, 2), out var m1) ||
            !int.TryParse(mmdd1.AsSpan(2, 2), out var d1) ||
            !int.TryParse(mmdd2.AsSpan(0, 2), out var m2) ||
            !int.TryParse(mmdd2.AsSpan(2, 2), out var d2))
            return 99;

        var year = DateTime.Now.Year;
        DateOnly? Make(int y, int m, int d)
        {
            try { return new DateOnly(y, m, d); } catch (ArgumentOutOfRangeException) { return null; }
        }

        if (Make(year, m1, d1) is not { } date1 || Make(year, m2, d2) is not { } date2)
            return 99;

        var diff = Math.Abs(date1.DayNumber - date2.DayNumber);
        // 跨年启发式：同年内差距 >180 天，大概率是 12月↔1月 跨年，在 -1/0/+1 年的组合里取最小
        if (diff > 180)
        {
            var best = diff;
            for (var dy1 = -1; dy1 <= 1; dy1++)
            {
                for (var dy2 = -1; dy2 <= 1; dy2++)
                {
                    if (Make(year + dy1, m1, d1) is { } a && Make(year + dy2, m2, d2) is { } b)
                        best = Math.Min(best, Math.Abs(a.DayNumber - b.DayNumber));
                }
            }
            diff = best;
        }
        return diff;
    }
}
