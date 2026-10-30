using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;
using Reimbursement.Core.Models;
using Reimbursement.Core.Trips;

namespace Reimbursement.Core.Storage;

/// <summary>
/// Session 生命周期管理：create → ingest → finalize → clear（对应 Swift SessionManager / Python collector）。
/// 数据落地（根目录由调用方给定；Windows 版为 %APPDATA%\Reimbursement）：
///   sessions/{sid}/manifest.json、originals/{filename}、trips/（finalize 后由打包层填充）。
/// </summary>
public sealed class SessionManager
{
    public SessionManifest Manifest { get; private set; }
    public string Sid { get; }
    public string RootDir { get; }

    public SessionManager(string sessionsRoot, string sid)
    {
        Sid = sid;
        RootDir = Path.Combine(sessionsRoot, sid);
        var manifestPath = Path.Combine(RootDir, "manifest.json");
        SessionManifest? loaded = null;
        if (File.Exists(manifestPath))
        {
            try
            {
                loaded = JsonSerializer.Deserialize<SessionManifest>(
                    File.ReadAllText(manifestPath), ReimburseJson.Options);
            }
            catch (Exception) { loaded = null; }
        }
        if (loaded != null)
        {
            Manifest = loaded;
        }
        else
        {
            Manifest = new SessionManifest(
                sid,
                DateTimeOffset.Now.ToString("yyyy-MM-dd'T'HH:mm:sszzz", CultureInfo.InvariantCulture),
                ocrAvailable: true, llmAvailable: false);
            Directory.CreateDirectory(Path.Combine(RootDir, "originals"));
            Save();
        }
    }

    // MARK: - 写入

    /// <summary>
    /// 把原始文件写到 originals/。
    /// overwrite=true 直接覆盖同名（登机牌裁切替换用）；false 时同名追加 -2/-3 后缀避免互相覆盖。
    /// 文件名清洗：mac 版只替换 "/"；Windows 额外替换 \ &lt; &gt; : " | ? * 与控制字符并去掉尾随点/空格（Windows 文件系统要求）。
    /// </summary>
    public string SaveOriginal(byte[] data, string filename, bool overwrite = false)
    {
        var safe = SanitizeFileName(filename);
        var dir = Path.Combine(RootDir, "originals");
        Directory.CreateDirectory(dir);

        if (overwrite)
        {
            var path = Path.Combine(dir, safe);
            File.WriteAllBytes(path, data);
            return path;
        }

        var candidate = Path.Combine(dir, safe);
        var ext = Path.GetExtension(safe);
        var baseName = ext.Length > 0 ? safe[..^ext.Length] : safe;
        var n = 2;
        while (File.Exists(candidate))
        {
            var name = ext.Length == 0 ? $"{baseName}-{n}" : $"{baseName}-{n}{ext}";
            candidate = Path.Combine(dir, name);
            n++;
        }
        File.WriteAllBytes(candidate, data);
        return candidate;
    }

    internal static string SanitizeFileName(string filename)
    {
        var chars = filename.Select(ch =>
            ch == '/' || ch == '\\' || ch == '<' || ch == '>' || ch == ':' || ch == '"' ||
            ch == '|' || ch == '?' || ch == '*' || ch < 0x20 ? '_' : ch).ToArray();
        return new string(chars).TrimEnd('.', ' ');
    }

    /// <summary>
    /// 追加一张识别后的票据。去重：以 sourceFile 打头的 dedup key 相同视为同一物理凭证的重复识别，
    /// 只保留 confidence 更高的一张（不同文件绝不互相去重）。
    /// </summary>
    public void Ingest(BillInfo bill)
    {
        var billKey = DedupKey(bill);
        var dupIdx = Manifest.Bills.FindIndex(b => DedupKey(b) == billKey);
        if (dupIdx >= 0)
        {
            if (bill.Confidence > Manifest.Bills[dupIdx].Confidence)
            {
                Manifest.Bills[dupIdx] = bill;
                Save();
            }
            return;
        }
        Manifest.Bills.Add(bill);
        if (bill.NeedsReview) Manifest.NeedsReviewCount += 1;
        Save();
    }

    private static string DedupKey(BillInfo bill)
    {
        var f = bill.Fields;
        string F(string k) => f.TryGetValue(k, out var v) ? v ?? "" : "";
        var amountKey = bill.Amount.ToString("F2", CultureInfo.InvariantCulture);
        return $"{bill.SourceFile}|{bill.BillType.ToRaw()}|{bill.DateRange.Start}_{bill.DateRange.End}|" +
               $"{bill.FromCity}>{bill.ToCity}|{amountKey}|{F("flight_no")}|{F("passenger_name")}|{F("room_no")}|{F("invoice_no")}";
    }

    /// <summary>
    /// finalize 完整流程（对应 Python finalize_session）：
    /// 1. 酒店发票↔水单 match + enrich 回填；2. 滴滴发票按金额链接行程单（继承日期/城市）；
    /// 3. TripResolver 行程归类；4. 每个行程/local 容器内分配滴滴字母与通行费序号；
    /// 5. 给所有 bill 填 targetSubdir/targetFilename；6. 同步回 manifest 并重算复核数。
    /// </summary>
    public void Finalize(IReadOnlySet<string>? homeCities = null)
    {
        homeCities ??= new HashSet<string>();
        var bills = Manifest.Bills;

        MatchAndEnrichHotel(bills);
        LinkDidiInvoices(bills);

        var (trips, local) = TripResolver.AssignTrips(bills, homeCities);
        foreach (var t in trips) AssignSequences(t.Bills);
        AssignSequences(local);

        foreach (var trip in trips)
        {
            var dirname = trip.Dirname;
            foreach (var b in trip.Bills)
            {
                b.TargetSubdir = dirname;
                b.TargetFilename = b.FinalTargetName.Length > 0 ? b.FinalTargetName : BuildFilename(b);
            }
        }
        foreach (var b in local)
        {
            b.TargetSubdir = "本地";
            b.TargetFilename = b.FinalTargetName.Length > 0 ? b.FinalTargetName : BuildFilename(b);
        }

        Manifest.Trips = trips;
        Manifest.Local = local;
        Manifest.Bills = trips.SelectMany(t => t.Bills).Concat(local).ToList();
        Manifest.NeedsReviewCount = Manifest.Bills.Count(b => b.NeedsReview);
        Save();

        // 把票据按行程目录复制到 trips/（完整打包的输入）。此前 Windows 版漏了这步，
        // trips/ 永不存在，ZipPackager.Package 恒抛"行程目录未生成"，打包无产物。
        Packaging.ZipPackager.ArrangeFiles(this);
    }

    // MARK: - hotel match + enrich

    /// <summary>
    /// 酒店水单 ↔ 发票匹配：金额完全相等（&lt;0.01）是必要条件；多个候选用酒店名/城市相似度消歧；
    /// 匹配成功后发票借用水单的日期范围/城市/酒店名回填（见 Enrich）。
    /// </summary>
    public static void MatchAndEnrichHotel(List<BillInfo> bills)
    {
        var folioIdxs = new List<int>();
        var invoiceIdxs = new List<int>();
        for (var i = 0; i < bills.Count; i++)
        {
            if (bills[i].BillType == BillType.HotelFolio) folioIdxs.Add(i);
            if (bills[i].BillType == BillType.HotelInvoice) invoiceIdxs.Add(i);
        }
        if (folioIdxs.Count == 0 || invoiceIdxs.Count == 0) return;

        var usedFolios = new HashSet<int>();
        foreach (var iIdx in invoiceIdxs)
        {
            var inv = bills[iIdx];
            if (inv.Amount <= 0) continue;

            var candidates = folioIdxs.Where(fIdx =>
                !usedFolios.Contains(fIdx) && bills[fIdx].Amount > 0 &&
                Math.Abs(inv.Amount - bills[fIdx].Amount) < 0.01).ToList();

            int? bestIdx = null;
            if (candidates.Count == 1) bestIdx = candidates[0];
            else if (candidates.Count > 1)
            {
                // 相似度最高者胜（并列时取先出现者，与 Swift max(by:) 的首胜语义一致）
                bestIdx = candidates
                    .OrderByDescending(c => HotelSimilarity(inv, bills[c]))
                    .First();
            }

            if (bestIdx is { } fIdx)
            {
                Enrich(inv, bills[fIdx]);
                usedFolios.Add(fIdx);
            }
        }
    }

    /// <summary>酒店名/销售方名的字符相似度（城市一致额外 +0.5，不封顶）。</summary>
    private static double HotelSimilarity(BillInfo invoice, BillInfo folio)
    {
        string? F(BillInfo b, string k) => b.Fields.TryGetValue(k, out var v) ? v : null;
        var invNames = new[] { F(invoice, "hotel_name"), F(invoice, "seller_name") }
            .Where(x => x != null).Cast<string>();
        var folioNames = new[] { F(folio, "hotel_name"), F(folio, "seller_name") }
            .Where(x => x != null).Cast<string>();

        var best = 0.0;
        foreach (var a in invNames)
            foreach (var b in folioNames)
                if (b.Length > 0) best = Math.Max(best, SimpleSimilarity(a, b));

        var invCity = F(invoice, "city") ?? invoice.Cities.FirstOrDefault() ?? "";
        var folioCity = F(folio, "city") ?? folio.Cities.FirstOrDefault() ?? "";
        if (invCity.Length > 0 && invCity == folioCity) best += 0.5;
        return best;
    }

    /// <summary>
    /// 发票缺失字段用水单回填（不覆盖已有值）+ folio 反向修正（日期范围/nights/city）+ 日期偏移复核标记；
    /// 最后按回填后的数据给发票算 finalTargetName。
    /// </summary>
    private static void Enrich(BillInfo invoice, BillInfo folio)
    {
        string F(BillInfo b, string k) => b.Fields.TryGetValue(k, out var v) ? v ?? "" : "";

        // 1) 日期范围（invoice 从 folio 补）
        if (invoice.DateRange.Start.Length == 0 || invoice.DateRange.Start == invoice.DateRange.End)
        {
            if (folio.DateRange.Start.Length > 0)
            {
                invoice.DateRange = folio.DateRange;
                invoice.Fields["check_in_date"] = folio.DateRange.Start;
                invoice.Fields["check_out_date"] =
                    folio.DateRange.End.Length == 0 ? folio.DateRange.Start : folio.DateRange.End;
            }
        }
        // 1b) folio 的 date_range 用 invoice 的 issue_date 修正（folio 的 LLM 常把开票日当入住日）
        var issueDate = F(invoice, "issue_date");
        if (issueDate.Length >= 10)
        {
            if (folio.DateRange.End.Length == 0 || folio.DateRange.End == folio.DateRange.Start)
            {
                var nightsStr = F(folio, "nights");
                if (int.TryParse(nightsStr, out var nights) && nights > 0 &&
                    ParseYmd(issueDate) is { } issueFull)
                {
                    var checkInFull = issueFull.AddDays(-(nights - 1));
                    folio.DateRange = (checkInFull.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
                                       BillInfo.Take(issueDate, 10));
                    folio.Fields["check_in_date"] = folio.DateRange.Start;
                    folio.Fields["check_out_date"] = folio.DateRange.End;
                }
                else
                {
                    folio.Fields["check_out_date"] = BillInfo.Take(issueDate, 10);
                    folio.DateRange = (folio.DateRange.Start, BillInfo.Take(issueDate, 10));
                }
            }
        }

        // 2) 晚数（invoice 从 folio 补）
        if (F(invoice, "nights").Length == 0 && F(folio, "nights").Length > 0)
            invoice.Fields["nights"] = F(folio, "nights");
        // 2b) folio 的 nights 从 invoice 推断（nights = issue_date − check_in_date + 1）
        if (F(folio, "nights").Length == 0)
        {
            var checkIn = F(folio, "check_in_date");
            var issue = F(invoice, "issue_date");
            if (checkIn.Length >= 10 && issue.Length >= 10)
            {
                var nights = DiffDays(checkIn, issue) + 1;
                if (nights > 0 && nights < 30)
                    folio.Fields["nights"] = nights.ToString(CultureInfo.InvariantCulture);
            }
        }

        // 3) 城市：invoice.cities 为空时从 folio 补
        if (invoice.Cities.Count == 0 && folio.Cities.Count > 0)
            invoice.Cities = new List<string>(folio.Cities);

        // 4) 房号/客人姓名/房型/酒店名 + 5) 品牌
        foreach (var k in new[] { "room_no", "guest_name", "room_type", "hotel_name", "brand" })
        {
            if (F(invoice, k).Length == 0 && F(folio, k).Length > 0)
                invoice.Fields[k] = F(folio, k);
        }

        // 6) 反向修 folio 的 city（LLM 可能把客人地址当酒店城市）：invoice.city 真实且不同 → 以 invoice 为准
        var folioCity = F(folio, "city");
        var invoiceCity = F(invoice, "city");
        if (invoiceCity.Length > 0 && folioCity.Length > 0 && invoiceCity != folioCity)
        {
            folio.Fields["city"] = invoiceCity;
            folio.Cities = new List<string> { invoiceCity };
        }

        // 7) 日期偏移检测：住宿区间与开票日最近相差 >1 天 → 标复核
        var ci = F(invoice, "check_in_date");
        var co = F(invoice, "check_out_date");
        var issue2 = F(invoice, "issue_date");
        if (ci.Length >= 10 && issue2.Length >= 10 &&
            ParseYmd(ci) is { } ciD && ParseYmd(issue2) is { } issueD)
        {
            var diffCI = Math.Abs(ciD.DayNumber - issueD.DayNumber);
            int? diffCO = co.Length >= 10 && ParseYmd(co) is { } coD
                ? Math.Abs(coD.DayNumber - issueD.DayNumber) : null;
            var minDiff = diffCO.HasValue ? Math.Min(diffCI, diffCO.Value) : diffCI;
            if (minDiff > 1)
            {
                invoice.NeedsReview = true;
                var warn = $"水单住 {ci}~{co} 与发票开具 {issue2} 最近相差 {minDiff} 天";
                invoice.ReviewReason = invoice.ReviewReason.Length == 0
                    ? $"日期偏移，{warn}" : $"{invoice.ReviewReason}；{warn}";
            }
        }

        // 8) match 成功后：用回填后的日期范围 + 城市生成最终文件名
        var newName = BuildFilename(invoice);
        if (newName != invoice.TargetFilename)
            invoice.FinalTargetName = newName;
    }

    /// <summary>简单字符级相似度：LCS 长度 / max(长度)（与 Swift simpleSimilarity 一致）。</summary>
    private static double SimpleSimilarity(string a, string b)
    {
        if (a.Length == 0 || b.Length == 0) return 0;
        var lcs = new int[a.Length + 1, b.Length + 1];
        for (var i = 0; i < a.Length; i++)
        {
            for (var j = 0; j < b.Length; j++)
            {
                lcs[i + 1, j + 1] = a[i] == b[j]
                    ? lcs[i, j] + 1
                    : Math.Max(lcs[i + 1, j], lcs[i, j + 1]);
            }
        }
        return (double)lcs[a.Length, b.Length] / Math.Max(a.Length, b.Length);
    }

    private static DateOnly? ParseYmd(string s)
    {
        if (s.Length < 10) return null;
        return DateOnly.TryParseExact(s[..10], "yyyy-MM-dd", CultureInfo.InvariantCulture,
            DateTimeStyles.None, out var d) ? d : null;
    }

    /// <summary>两个 YYYY-MM-DD 的天数差（b − a，带符号；解析失败返回 -1，与 Swift diffDays 一致）。</summary>
    private static int DiffDays(string a, string b)
    {
        if (a.Length < 10 || b.Length < 10) return -1;
        if (ParseYmd(a) is not { } d1 || ParseYmd(b) is not { } d2) return -1;
        return d2.DayNumber - d1.DayNumber;
    }

    // MARK: - didi 字母分配 + toll 序号

    /// <summary>A → B → … → Z → AA → AB …（进位规则与 Swift incrementLetter 一致）。</summary>
    private static string IncrementLetter(string s)
    {
        var chars = s.ToCharArray();
        for (var i = chars.Length - 1; i >= 0; i--)
        {
            if (chars[i] == 'Z') chars[i] = 'A';
            else
            {
                chars[i] = (char)(chars[i] + 1);
                return new string(chars);
            }
        }
        return "A" + new string(chars);
    }

    /// <summary>
    /// 容器内序号分配（每个行程/local 各自独立）：
    /// 1) didi_trip 按 trip_period/departure_date 升序发字母；2) didi_invoice 按金额继承行程单字母（无匹配自取新字母）；
    /// 3) toll_invoice 按顺序写 01/02…（借用 DidiLetter 字段）。
    /// </summary>
    public static void AssignSequences(List<BillInfo> container)
    {
        var usedLetters = new HashSet<string>();
        var nextLetter = "A";
        string NextAvailableLetter()
        {
            var candidate = nextLetter;
            while (usedLetters.Contains(candidate)) candidate = IncrementLetter(candidate);
            usedLetters.Add(candidate);
            nextLetter = IncrementLetter(candidate);
            return candidate;
        }

        // 1) didi_trip 按行程时间升序（稳定排序）
        var tripIndices = container.Select((b, i) => (b, i))
            .Where(x => x.b.BillType == BillType.DidiTrip)
            .OrderBy(x => DidiSortKey(x.b), StringComparer.Ordinal)
            .Select(x => x.i);
        foreach (var i in tripIndices)
            container[i].DidiLetter = NextAvailableLetter();

        // 2) didi_invoice 按金额匹配已有 didi_trip
        var matchedTripIdxs = new HashSet<int>();
        for (var i = 0; i < container.Count; i++)
        {
            if (container[i].BillType != BillType.DidiInvoice) continue;
            var matchedLetter = "";
            if (container[i].Amount > 0)
            {
                for (var j = 0; j < container.Count; j++)
                {
                    if (container[j].BillType != BillType.DidiTrip || matchedTripIdxs.Contains(j)) continue;
                    if (container[j].Amount > 0 &&
                        Math.Abs(container[j].Amount - container[i].Amount) < 0.01)
                    {
                        matchedLetter = container[j].DidiLetter;
                        matchedTripIdxs.Add(j);
                        break;
                    }
                }
            }
            container[i].DidiLetter = matchedLetter.Length == 0 ? NextAvailableLetter() : matchedLetter;
        }

        // 3) toll_invoice 顺序序号
        var tollSeq = 1;
        for (var i = 0; i < container.Count; i++)
        {
            if (container[i].BillType != BillType.TollInvoice) continue;
            container[i].DidiLetter = tollSeq.ToString("D2", CultureInfo.InvariantCulture);
            tollSeq++;
        }
    }

    /// <summary>didi_trip 排序键：优先 trip_period，退化 departure_date；空值排最后（"9999"）。</summary>
    private static string DidiSortKey(BillInfo b)
    {
        if (b.F("trip_period") is { Length: > 0 } p) return p;
        if (b.F("departure_date") is { Length: > 0 } d) return d;
        return "9999";
    }

    /// <summary>
    /// 滴滴发票 ↔ 行程单按金额配对（&lt;0.01），发票整份继承行程单的日期/MMDD/城市，
    /// 确保二者在 TripResolver 里归到同一行程（滴滴批量开票的 issue_date 扎堆在最后一天，不对齐会全挂到最后一个行程）。
    /// </summary>
    public static void LinkDidiInvoices(List<BillInfo> bills)
    {
        var tripIndices = bills.Select((b, i) => (b, i))
            .Where(x => x.b.BillType == BillType.DidiTrip).Select(x => x.i).ToList();
        var used = new HashSet<int>();
        for (var i = 0; i < bills.Count; i++)
        {
            if (bills[i].BillType != BillType.DidiInvoice || bills[i].Amount <= 0) continue;
            foreach (var j in tripIndices)
            {
                if (used.Contains(j) || bills[j].Amount <= 0) continue;
                if (Math.Abs(bills[j].Amount - bills[i].Amount) < 0.01)
                {
                    bills[i].DateMMDDs = new List<string>(bills[j].DateMMDDs);
                    bills[i].DateRange = bills[j].DateRange;
                    bills[i].Cities = new List<string>(bills[j].Cities);
                    bills[i].FromCity = bills[j].FromCity;
                    bills[i].ToCity = bills[j].ToCity;
                    used.Add(j);
                    break;
                }
            }
        }
    }

    // MARK: - 单张维护

    /// <summary>
    /// 删除单张票据（按 uid），并重算复核数。三处副本（Bills / 各行程 Bills / Local）
    /// 必须同步删除——只删 Bills 会让已删票据在整合 PDF / 打包里从行程副本中"复活"。
    /// </summary>
    public void RemoveBill(string uid)
    {
        Manifest.Bills.RemoveAll(b => b.Uid == uid);
        foreach (var trip in Manifest.Trips)
            trip.Bills.RemoveAll(b => b.Uid == uid);
        Manifest.Local.RemoveAll(b => b.Uid == uid);
        Manifest.NeedsReviewCount = Manifest.Bills.Count(b => b.NeedsReview);
        Save();
    }

    /// <summary>用同 uid 的新识别结果替换旧票据（重新识别用）；找不到则追加。</summary>
    public void ReplaceBill(BillInfo bill)
    {
        var idx = Manifest.Bills.FindIndex(b => b.Uid == bill.Uid);
        if (idx >= 0) Manifest.Bills[idx] = bill;
        else Manifest.Bills.Add(bill);
        Manifest.NeedsReviewCount = Manifest.Bills.Count(b => b.NeedsReview);
        Save();
    }

    /// <summary>清空整个 session（删除目录）。</summary>
    public void Clear()
    {
        if (Directory.Exists(RootDir)) Directory.Delete(RootDir, recursive: true);
    }

    /// <summary>持久化 manifest（先写临时文件再覆盖，近似原子写）。</summary>
    public void Save()
    {
        Directory.CreateDirectory(RootDir);
        var path = Path.Combine(RootDir, "manifest.json");
        var tmp = path + ".tmp";
        File.WriteAllText(tmp, JsonSerializer.Serialize(Manifest, ReimburseJson.Options));
        File.Move(tmp, path, overwrite: true);
    }

    // MARK: - 文件名生成

    /// <summary>
    /// 按票据类型生成规范文件名（对应 Swift buildFilename / Python _build_filename）。
    /// 注意：扩展名硬编码 .pdf（与原文件真实格式无关，是既有归档习惯，见分析报告 §7）。
    /// 例：火车票「0303 北京-上海 553.pdf」、酒店水单「0910-0912 厦门住宿水单.pdf」、滴滴「滴滴电子发票A.pdf」。
    /// </summary>
    public static string BuildFilename(BillInfo bill)
    {
        const string suf = ".pdf";
        var bt = bill.BillType;
        var f = bill.Fields;
        string F(string k) => f.TryGetValue(k, out var v) ? v ?? "" : "";

        // 第一个非空的 MMDD
        var dateMmdd = "";
        foreach (var d in bill.DateMMDDs)
        {
            if (d.Length == 0) continue;
            var s = BillInfo.Take(d, 4);
            if (s.Length == 4) { dateMmdd = s; break; }
        }
        if (dateMmdd.Length == 0)
        {
            foreach (var fk in new[] { "issue_date", "check_in_date", "departure_date" })
            {
                var v = F(fk);
                if (v.Length >= 10)
                {
                    dateMmdd = v.Substring(5, 2) + v.Substring(8, 2);
                    break;
                }
            }
        }

        var fmtAmount = FmtAmount(bill.Amount);
        var route = bill.FromCity.Length == 0 || bill.ToCity.Length == 0
            ? "" : $"{bill.FromCity}-{bill.ToCity}";
        string JoinNonEmpty(params string[] parts) =>
            string.Join(" ", parts.Where(p => p.Length > 0));

        switch (bt)
        {
            case BillType.TrainTicket:
            {
                var parts = JoinNonEmpty(dateMmdd, route, fmtAmount);
                return parts.Length == 0 ? $"火车票{dateMmdd}{suf}" : parts + suf;
            }
            case BillType.FlightItinerary:
            {
                var parts = JoinNonEmpty(dateMmdd, F("flight_no"), route, fmtAmount);
                return parts.Length == 0 ? $"机票行程单{suf}" : parts + suf;
            }
            case BillType.BoardingPass:
            {
                var parts = JoinNonEmpty(dateMmdd, route, "登机牌");
                return parts.Length == 0 ? $"登机牌{suf}" : parts + suf;
            }
            case BillType.SelfDriveSheet:
            {
                return JoinNonEmpty("高速路行程单", dateMmdd, route) + suf;
            }
            case BillType.DidiTrip:
            {
                var letter = bill.DidiLetter.Length == 0 ? "X" : bill.DidiLetter;
                return $"滴滴出行行程报销单{letter}{suf}";
            }
            case BillType.DidiInvoice:
            {
                var letter = bill.DidiLetter.Length == 0 ? "X" : bill.DidiLetter;
                return $"滴滴电子发票{letter}{suf}";
            }
            case BillType.HotelFolio:
            case BillType.HotelInvoice:
            {
                var s = bill.DateRange.Start;
                var e = bill.DateRange.End;
                // city 优先级：fields.city > cities[0] > seller_name 正则提取 > seller 前 4 字 > 未知
                var city = F("city");
                if (city.Length == 0 && bill.Cities.Count > 0) city = bill.Cities[0];
                if (city.Length == 0)
                {
                    var seller = F("seller_name").Length > 0 ? F("seller_name") : F("hotel_name");
                    city = ExtractHotelCity(seller) ?? BillInfo.Take(seller, 4);
                }
                if (city.Length == 0) city = "未知";

                string dateSeg;
                if (s.Length > 0 && e.Length > 0 && s != e)
                    dateSeg = $"{Mmdd(s)}-{Mmdd(e)}";
                else
                    dateSeg = s.Length > 0 ? Mmdd(s) : dateMmdd;
                var suffixWord = bt == BillType.HotelFolio ? "住宿水单" : "住宿发票";
                return dateSeg.Length == 0 ? $"{city}{suffixWord}{suf}" : $"{dateSeg} {city}{suffixWord}{suf}";
            }
            case BillType.TaxiTransport:
            {
                var parts = JoinNonEmpty(dateMmdd, "出租车发票", fmtAmount);
                return parts.Length == 0 ? $"出租车{suf}" : parts + suf;
            }
            case BillType.GasInvoice:
            {
                var parts = JoinNonEmpty(dateMmdd, "加油费", fmtAmount);
                return parts.Length == 0 ? $"加油费{suf}" : parts + suf;
            }
            case BillType.TollInvoice:
            {
                var seq = bill.DidiLetter.Length == 0 ? "01" : bill.DidiLetter;
                var parts = JoinNonEmpty(dateMmdd, $"通行费{seq}", fmtAmount);
                return parts.Length == 0 ? $"通行费{suf}" : parts + suf;
            }
            case BillType.Dining:
            {
                var city = F("city").Length > 0 ? F("city") : bill.Cities.FirstOrDefault() ?? "";
                var cityDining = city.Length == 0 ? "餐饮发票" : $"{city}餐饮发票";
                var parts = JoinNonEmpty(dateMmdd, cityDining, fmtAmount);
                return parts.Length == 0 ? $"餐饮{suf}" : parts + suf;
            }
            case BillType.Telecom:
            {
                var parts = JoinNonEmpty(dateMmdd, "通信发票", fmtAmount);
                return parts.Length == 0 ? $"通信{suf}" : parts + suf;
            }
            default: // Other
            {
                var parts = JoinNonEmpty(dateMmdd, fmtAmount);
                if (parts.Length > 0) return parts + suf;
                var stem = Path.GetFileNameWithoutExtension(bill.SourceFile);
                return stem.Length == 0 ? $"其他{suf}" : $"{stem}{suf}";
            }
        }
    }

    /// <summary>金额格式化：%.2f 后去尾零与尾点（239.00 → "239"；239.50 → "239.5"——注意与 Swift 的正则去尾零结果一致）；≤0 返回空串。</summary>
    private static string FmtAmount(double amount)
    {
        if (amount <= 0) return "";
        var s = amount.ToString("F2", CultureInfo.InvariantCulture);
        if (s.Contains('.'))
        {
            s = s.TrimEnd('0');
            s = s.TrimEnd('.');
        }
        return s.Length == 0 ? "0" : s;
    }

    /// <summary>从酒店全名提取城市：「上海外滩茂悦大酒店」→「上海」（正则与 Swift 版一致）。</summary>
    private static string? ExtractHotelCity(string seller)
    {
        if (seller.Length == 0) return null;
        var pattern = @"([\u4e00-\u9fa5]{2,3}(?:[\u4e00-\u9fa5]{0,2})?(?:酒店|饭店))";
        var m = Regex.Match(seller, pattern);
        if (!m.Success) return null;
        return m.Groups[1].Value.Replace("酒店", "").Replace("饭店", "");
    }

    /// <summary>YYYY-MM-DD → MMDD（短于 10 字符原样返回，与 Swift mmdd 一致）。</summary>
    private static string Mmdd(string s)
    {
        if (s.Length < 10) return s;
        return s.Substring(5, 2) + s.Substring(8, 2);
    }
}

/// <summary>会话内一段行程的概要（会话列表展开区用）。</summary>
public sealed record SessionTripBrief(string Dirname, int BillCount, double Amount);

/// <summary>会话摘要（列表页用）。</summary>
public sealed record SessionSummary(string Sid, string CreatedAt, int BillCount, int TripCount)
{
    /// <summary>全部票据金额合计。</summary>
    public double TotalAmount { get; init; }
    /// <summary>逐行程概要（整理后才有）。</summary>
    public IReadOnlyList<SessionTripBrief> TripBriefs { get; init; } = Array.Empty<SessionTripBrief>();
    /// <summary>本地票据张数与金额合计（整理后才有）。</summary>
    public int LocalCount { get; init; }
    public double LocalAmount { get; init; }

    /// <summary>创建时间展示：ISO 8601 UTC → 本地时区 "yyyy-MM-dd HH:mm"（解析失败退化为截断替换）。</summary>
    public string CreatedLabel
    {
        get
        {
            if (DateTimeOffset.TryParse(CreatedAt, CultureInfo.InvariantCulture,
                    DateTimeStyles.RoundtripKind, out var dto))
            {
                return dto.LocalDateTime.ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture);
            }
            return BillInfo.Take(CreatedAt, 16).Replace("T", " ");
        }
    }
}

/// <summary>会话目录工具（对应 Swift Sessions）。根目录由调用方给定。</summary>
public static class Sessions
{
    public static string CreateNewSid() => Guid.NewGuid().ToString().ToLowerInvariant();

    /// <summary>列出所有已保存的会话摘要（按创建时间倒序，字符串序）。</summary>
    public static List<SessionSummary> List(string sessionsRoot)
    {
        var result = new List<SessionSummary>();
        if (!Directory.Exists(sessionsRoot)) return result;
        foreach (var dir in Directory.EnumerateDirectories(sessionsRoot))
        {
            var manifestPath = Path.Combine(dir, "manifest.json");
            if (!File.Exists(manifestPath)) continue;
            try
            {
                var m = JsonSerializer.Deserialize<SessionManifest>(
                    File.ReadAllText(manifestPath), ReimburseJson.Options);
                if (m == null) continue;
                result.Add(new SessionSummary(m.Sid, m.CreatedAt, m.Bills.Count, m.Trips.Count)
                {
                    TotalAmount = m.Bills.Sum(b => b.Amount),
                    TripBriefs = m.Trips.Select(t => new SessionTripBrief(
                        t.Dirname, t.Bills.Count, t.Bills.Sum(b => b.Amount))).ToList(),
                    LocalCount = m.Local.Count,
                    LocalAmount = m.Local.Sum(b => b.Amount),
                });
            }
            catch (Exception) { /* 损坏的 manifest 跳过，与 Swift 版一致 */ }
        }
        return result.OrderByDescending(x => x.CreatedAt, StringComparer.Ordinal).ToList();
    }

    /// <summary>清空所有历史会话（删除 sessions 目录下全部子目录，保留目录本身）。</summary>
    public static void ClearAll(string sessionsRoot)
    {
        if (!Directory.Exists(sessionsRoot)) return;
        foreach (var dir in Directory.EnumerateDirectories(sessionsRoot))
            Directory.Delete(dir, recursive: true);
        foreach (var file in Directory.EnumerateFiles(sessionsRoot))
            File.Delete(file);
    }
}
