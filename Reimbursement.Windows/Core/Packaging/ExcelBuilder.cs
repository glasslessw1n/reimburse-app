using System.Globalization;
using System.IO.Compression;
using System.Text;
using Reimbursement.Core.Models;
using Reimbursement.Core.Trips;

namespace Reimbursement.Core.Packaging;

/// <summary>
/// 手写生成 xlsx 报销明细（不依赖第三方库）。对应 Swift ExcelBuilder 的 1:1 移植。
/// 版式以用户 2026-11-09 提供的目标样例（0910-1026.xlsx）为准（与 mac 版同版）：
/// 5 列、行程/本地分段、每段固定骨架（铁路交通标签 + 交通小计、酒店小计、滴滴
/// 汇总行）、日期 MM/DD、备注列写整理后的目标文件名、总计行带分类整数明细。
///
/// 与 Swift 版的 API 差异：Swift 的 build(bills:homeCities:outputURL:) 把 XML 写到临时目录后
/// 调用 /usr/bin/zip 打包到目标路径；此处改为进程内用 System.IO.Compression.ZipArchive 组装，
/// 主入口 Build(...) 直接返回 xlsx 字节，SaveTo(path,...) 是对应的落盘便捷方法。
/// BuildSheet(...) 与 Swift 同名内部入口一致（返回 sheet1.xml 字符串），供测试直接断言。
/// </summary>
public static class ExcelBuilder
{
/// <summary>生成 xlsx 并返回字节（对应 Swift build 到 outputURL 的产物内容）。</summary>
public static byte[] Build(IReadOnlyList<BillInfo> bills, IReadOnlySet<string> homeCities)
{
using var ms = new MemoryStream();
using (var zip = new ZipArchive(ms, ZipArchiveMode.Create, leaveOpen: true))
{
WriteEntry(zip, "[Content_Types].xml", ContentTypesXml);
WriteEntry(zip, "_rels/.rels", RootRelsXml);
WriteEntry(zip, "xl/workbook.xml", BuildWorkbook());
WriteEntry(zip, "xl/_rels/workbook.xml.rels", WorkbookRelsXml);
WriteEntry(zip, "xl/worksheets/sheet1.xml", BuildSheet(bills, homeCities));
WriteEntry(zip, "xl/styles.xml", StylesXml);
}
return ms.ToArray();
}

/// <summary>生成 xlsx 并写入指定路径（对应 Swift build 的 outputURL 落盘语义）。</summary>
public static void SaveTo(string outputPath, IReadOnlyList<BillInfo> bills, IReadOnlySet<string> homeCities)
{
File.WriteAllBytes(outputPath, Build(bills, homeCities));
}

private static void WriteEntry(ZipArchive zip, string name, string content)
{
var entry = zip.CreateEntry(name);
using var stream = entry.Open();
var bytes = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false).GetBytes(content);
stream.Write(bytes, 0, bytes.Length);
}

// MARK: - XML 工具

private static string XmlEscape(string s) => s
.Replace("&", "&amp;")
.Replace("<", "&lt;")
.Replace(">", "&gt;")
.Replace("\"", "&quot;");

// MARK: - 静态 XML 模板

/// <summary>`[Content_Types].xml`</summary>
private const string ContentTypesXml = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
</Types>
""";

/// <summary>`_rels/.rels`</summary>
private const string RootRelsXml = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>
""";

/// <summary>`xl/workbook.xml`</summary>
private static string BuildWorkbook()
{
return """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<sheets>
<sheet name="报销明细" sheetId="1" r:id="rId1"/>
</sheets>
</workbook>
""";
}

/// <summary>`xl/_rels/workbook.xml.rels`</summary>
private const string WorkbookRelsXml = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
</Relationships>
""";

/// <summary>`xl/styles.xml`</summary>
private const string StylesXml = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<fonts count="5">
<font><sz val="10"/><name val="Microsoft YaHei"/></font>
<font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="Microsoft YaHei"/></font>
<font><b/><sz val="12"/><name val="Microsoft YaHei"/></font>
<font><b/><sz val="13"/><color rgb="FFFFFFFF"/><name val="Microsoft YaHei"/></font>
<font><b/><sz val="10"/><name val="Microsoft YaHei"/></font>
</fonts>
<fills count="6">
<fill><patternFill patternType="none"/></fill>
<fill><patternFill patternType="gray125"/></fill>
<fill><patternFill><fgColor rgb="FFD6E4F0"/></patternFill></fill>
<fill><patternFill><fgColor rgb="FFFFF2CC"/></patternFill></fill>
<fill><patternFill><fgColor rgb="FFE2EFDA"/></patternFill></fill>
<fill><patternFill><fgColor rgb="FF4472C4"/></patternFill></fill>
</fills>
<borders count="2">
<border/>
<border>
<left style="thin"/><right style="thin"/><top style="thin"/><bottom style="thin"/>
</border>
</borders>
<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
<cellXfs count="12">
<xf numFmtId="0" fontId="0" fillId="0" borderId="1" applyAlignment="1"><alignment vertical="center" wrapText="1"/></xf>
<xf numFmtId="0" fontId="1" fillId="5" borderId="1" applyAlignment="1"><alignment horizontal="center" vertical="center" wrapText="1"/></xf>
<xf numFmtId="0" fontId="2" fillId="2" borderId="1" applyAlignment="1"><alignment vertical="center" wrapText="1"/></xf>
<xf numFmtId="0" fontId="4" fillId="3" borderId="1" applyAlignment="1"><alignment horizontal="right" vertical="center"/></xf>
<xf numFmtId="4" fontId="0" fillId="0" borderId="1" applyAlignment="1"><alignment horizontal="right" vertical="center"/></xf>
<xf numFmtId="0" fontId="0" fillId="0" borderId="1" applyAlignment="1"><alignment horizontal="center" vertical="center" wrapText="1"/></xf>
<xf numFmtId="0" fontId="4" fillId="0" borderId="1" applyAlignment="1"><alignment vertical="center"/></xf>
<xf numFmtId="0" fontId="2" fillId="4" borderId="1" applyAlignment="1"><alignment vertical="center"/></xf>
<xf numFmtId="0" fontId="3" fillId="5" borderId="1" applyAlignment="1"><alignment vertical="center"/></xf>
<xf numFmtId="0" fontId="4" fillId="4" borderId="1" applyAlignment="1"><alignment vertical="center"/></xf>
<xf numFmtId="4" fontId="4" fillId="3" borderId="1" applyAlignment="1"><alignment horizontal="right" vertical="center"/></xf>
<xf numFmtId="0" fontId="4" fillId="3" borderId="1" applyAlignment="1"><alignment vertical="center"/></xf>
</cellXfs>
<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
<numFmts count="1">
<numFmt numFmtId="4" formatCode="#,##0.00"/>
</numFmts>
</styleSheet>
""";

// MARK: - sheet1.xml 构建

/// <summary>`xl/worksheets/sheet1.xml`（与 Swift buildSheet 同名入口，内部重跑 TripResolver）。</summary>
public static string BuildSheet(IReadOnlyList<BillInfo> bills, IReadOnlySet<string> homeCities)
{
var (trips, localBills) = TripResolver.AssignTrips(bills, homeCities);
var totalsByCategory = new Dictionary<string, double>
{
["自驾车"] = 0, ["交通"] = 0, ["酒店"] = 0, ["滴滴"] = 0, ["餐饮"] = 0, ["通信"] = 0, ["其他"] = 0
};

var rowsXML = new List<string>();
var merges = new List<string>();
// 表头
rowsXML.Add(MakeRow(1, new[]
{
("A", "票据类别", 1),
("B", "日期/区间", 1),
("C", "金额(¥)", 1),
("D", "明细", 1),
("E", "备注", 1)
}));
var rowIdx = 2;

foreach (var trip in trips)
{
rowIdx = RenderTrip(trip, rowIdx, rowsXML, merges, totalsByCategory);
}
if (localBills.Count > 0)
{
rowIdx = RenderLocal(localBills, rowIdx, rowsXML, merges, totalsByCategory);
}
// 总计行前留一空行（样例版式）：只推进计数、不出行元素
rowIdx += 1;
var nextRow = RenderGrandTotal(rowIdx, rowsXML, merges, totalsByCategory);
var lastRow = nextRow - 1;

var body = string.Concat(rowsXML);
var mergeXML = merges.Count == 0 ? "" :
"<mergeCells count=\"" + merges.Count + "\">"
+ string.Concat(merges.Select(m => $"<mergeCell ref=\"{m}\"/>"))
+ "</mergeCells>";
return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
+ "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
+ "<sheetViews><sheetView workbookViewId=\"0\">"
+ "<pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/>"
+ "<selection pane=\"bottomLeft\" activeCell=\"A2\" sqref=\"A2\"/>"
+ "</sheetView></sheetViews>"
+ "<cols>"
+ "<col min=\"1\" max=\"1\" width=\"14\" customWidth=\"1\"/>"
+ "<col min=\"2\" max=\"2\" width=\"18\" customWidth=\"1\"/>"
+ "<col min=\"3\" max=\"3\" width=\"12\" customWidth=\"1\"/>"
+ "<col min=\"4\" max=\"4\" width=\"30\" customWidth=\"1\"/>"
+ "<col min=\"5\" max=\"5\" width=\"24\" customWidth=\"1\"/>"
+ "</cols>"
+ "<sheetData>" + body + "</sheetData>"
+ $"<autoFilter ref=\"A1:E{lastRow}\"/>"
+ mergeXML
+ "<pageMargins left=\"0.7\" right=\"0.7\" top=\"0.75\" bottom=\"0.75\" header=\"0.3\" footer=\"0.3\"/>"
+ "<pageSetup orientation=\"landscape\"/>"
+ "</worksheet>";
}

// MARK: - 行/单元格构建

/// <summary>
/// 生成 &lt;row r="idx"&gt;cells&lt;/row&gt;；cells 为 (列字母, 值, style)，值均为字符串（inlineStr）。
/// amountC 非 null 时，C 列改写数值单元格（可被 Excel 求和，与样例一致）。
/// </summary>
private static string MakeRow(int idx, IReadOnlyList<(string Col, string Value, int Style)> cells, double? amountC = null)
{
var sb = new StringBuilder();
sb.Append("<row r=\"").Append(idx).Append("\">");
foreach (var (col, value, style) in cells)
{
if (col == "C" && amountC is { } amount)
sb.Append(MakeNumberCell($"{col}{idx}", amount, style));
else
sb.Append(MakeInlineStringCell($"{col}{idx}", value, style));
}
sb.Append("</row>");
return sb.ToString();
}

/// <summary>数字单元格。</summary>
private static string MakeNumberCell(string @ref, double value, int style) =>
$"<c r=\"{@ref}\" s=\"{style}\"><v>{FmtNumber(value)}</v></c>";

/// <summary>inline 字符串单元格（避免 sharedStrings.xml）。</summary>
private static string MakeInlineStringCell(string @ref, string value, int style) =>
$"<c r=\"{@ref}\" s=\"{style}\" t=\"inlineStr\"><is><t>{XmlEscape(value)}</t></is></c>";

/// <summary>合并行（5 列合并成 1 列文本）。</summary>
private static string MakeMergedRow(int idx, string text, int style)
{
var escaped = XmlEscape(text);
return $"<row r=\"{idx}\"><c r=\"A{idx}\" s=\"{style}\" t=\"inlineStr\"><is><t>{escaped}</t></is></c></row>";
}

private static string FmtNumber(double v) => v.ToString("F2", CultureInfo.InvariantCulture);

/// <summary>千分位 + 两位小数（合计/总计的金额文本用，如 1,703.50）。</summary>
private static string FmtMoney(double v) => GroupThousands(FmtNumber(v));

/// <summary>四舍五入到整数 + 千分位（总计行分类明细用，如 1,999）。</summary>
private static string FmtIntGrouped(double v) =>
GroupThousands(((long)Math.Round(v)).ToString(CultureInfo.InvariantCulture));

private static string GroupThousands(string s)
{
var intPart = s;
var frac = "";
var dot = s.IndexOf('.');
if (dot >= 0)
{
intPart = s[..dot];
frac = s[dot..];
}
var sb = new StringBuilder();
for (var i = 0; i < intPart.Length; i++)
{
if (i > 0 && (intPart.Length - i) % 3 == 0) sb.Append(',');
sb.Append(intPart[i]);
}
return sb.ToString() + frac;
}

/// <summary>MMDD → MM/DD（样例的日期写法）。</summary>
private static string SlashMMDD(string mmdd) =>
mmdd.Length == 4 ? $"{mmdd[..2]}/{mmdd[2..]}" : mmdd;

/// <summary>票据首日期（MM/DD 形式）。</summary>
private static string FirstSlash(BillInfo b) => SlashMMDD(FirstMMDD(b));

/// <summary>备注列文件名：优先整理后的目标文件名（与 ZIP 包内一致），未整理时回退原文件名。</summary>
private static string NoteName(BillInfo b) =>
b.TargetFilename.Length > 0 ? b.TargetFilename : b.SourceFile;

/// <summary>通信费月份标签：month 字段（YYYY-MM）→「10月」；缺失时用日期月份。</summary>
private static string TelecomMonth(BillInfo b)
{
if (b.F("month") is { Length: >= 7 } m)
return $"{int.Parse(m.Substring(5, 2))}月";
var s = b.DateRange.Start;
if (s.Length >= 7)
return $"{int.Parse(s.Substring(5, 2))}月";
return "";
}

/// <summary>小计行（样例版式：只有 B 标签 + C 金额两格，A/D/E 不出单元格）。</summary>
private static string SubtotalRow(int idx, string label, double amount) =>
$"<row r=\"{idx}\">"
+ MakeInlineStringCell($"B{idx}", label, 11)
+ (amount > 0
? MakeNumberCell($"C{idx}", amount, 10)
: MakeInlineStringCell($"C{idx}", "-", 3))
+ "</row>";

/// <summary>
/// 滴滴覆盖判定（与 mac 版一致）：一张发票可覆盖若干张行程单（金额之和相等），
/// 返回被覆盖的行程单下标集合。旧实现只认「单张金额恰好相等」，汇总发票（一张
/// 盖多段）覆盖不了任何单张，发票与行程单金额会被重复计入。按分（整数）做子集
/// 和匹配避免浮点误差；候选按金额降序带剪枝回溯，节点上限兜底。
/// </summary>
private static HashSet<int> DidiCoveredTrips(
IReadOnlyList<double> invoiceAmounts, IReadOnlyList<double> tripAmounts)
{
static int Cents(double v) => (int)Math.Round(v * 100);
var remaining = new List<int>();
for (var i = 0; i < tripAmounts.Count; i++)
if (tripAmounts[i] > 0) remaining.Add(i);
var covered = new HashSet<int>();
foreach (var inv in invoiceAmounts)
{
if (inv <= 0) continue;
var target = Cents(inv);
if (target <= 0) continue;
var candidates = remaining.OrderByDescending(i => tripAmounts[i]).ToList();
var chosen = new List<int>();
var nodes = 0;
bool Search(int pos, int sum)
{
if (sum == target) return true;
if (sum > target || pos >= candidates.Count) return false;
nodes++;
if (nodes > 20000) return false;
var ci = candidates[pos];
chosen.Add(ci);
if (Search(pos + 1, sum + Cents(tripAmounts[ci]))) return true;
chosen.RemoveAt(chosen.Count - 1);
return Search(pos + 1, sum);
}
if (Search(0, 0))
{
foreach (var ci in chosen) covered.Add(ci);
remaining.RemoveAll(i => chosen.Contains(i));
}
}
return covered;
}

private static void AddTotal(Dictionary<string, double> totals, string key, double delta)
{
totals.TryGetValue(key, out var cur);
totals[key] = cur + delta;
}

// MARK: - 行程渲染

private static int RenderTrip(
TripGroup trip,
int startRow,
List<string> rows,
List<string> merges,
Dictionary<string, double> totals)
{
var rowIdx = startRow;

// 行程标题（A:E 合并）
rows.Add(MakeMergedRow(rowIdx, $"【{trip.Dirname}】", 2));
merges.Add($"A{rowIdx}:E{rowIdx}");
rowIdx += 1;

// 分类
var transport = trip.Bills.Where(b => IsTransportType(b.BillType))
.OrderBy(b => FirstMMDD(b), StringComparer.Ordinal).ToList();
var selfDrive = trip.Bills.Where(b => b.BillType == BillType.SelfDriveSheet).ToList();
var hotelFolios = trip.Bills.Where(b => b.BillType == BillType.HotelFolio)
.OrderBy(b => b.DateRange.Start, StringComparer.Ordinal).ToList();
var hotelInvoices = trip.Bills.Where(b => b.BillType == BillType.HotelInvoice)
.OrderBy(b => b.DateRange.Start, StringComparer.Ordinal).ToList();
var didiTrip = trip.Bills.Where(b => b.BillType == BillType.DidiTrip).ToList();
var didiInvoice = trip.Bills.Where(b => b.BillType == BillType.DidiInvoice).ToList();
var dining = trip.Bills.Where(b => b.BillType == BillType.Dining).ToList();
var gas = trip.Bills.Where(b => b.BillType == BillType.GasInvoice || b.BillType == BillType.TollInvoice).ToList();

var tripTotal = 0.0;

// 0. 自驾车 + 加油 + 通行费
if (selfDrive.Count > 0 || gas.Count > 0)
{
foreach (var b in selfDrive)
{
var route = $"{b.FromCity}-{b.ToCity}";
rows.Add(MakeRow(rowIdx, new[]
{
("A", "自驾车行程单", 0),
("B", "-", 5),
("C", "-", 5),
("D", route, 0),
("E", NoteName(b), 0)
}));
rowIdx += 1;
}
var sub = 0.0;
foreach (var b in gas)
{
var cat = b.BillType == BillType.TollInvoice? "通行费": "加油费";
var date = FirstSlash(b);
if (b.Amount > 0) { sub += b.Amount; tripTotal += b.Amount;}
rows.Add(MakeRow(rowIdx, new[]
{
("A", cat, 0),
("B", date, 5),
("C", FmtNumber(b.Amount), 4),
("D", "", 0),
("E", NoteName(b), 0)
}, amountC: b.Amount));
rowIdx += 1;
}
rows.Add(SubtotalRow(rowIdx, "自驾车小计", sub));
rowIdx += 1;
AddTotal(totals, "自驾车", sub);
}

// 1. 交通（固定骨架：标签行 + 票据行 + 小计，无票据时也出小计「-」）
//    标签行只有 A 一格；类别名：登机牌 / 火车/机票（火车票与机票行程单同名）
rows.Add($"<row r=\"{rowIdx}\">"
+ MakeInlineStringCell($"A{rowIdx}", "铁路交通", 6)
+ "</row>");
rowIdx += 1;
var transportSub = 0.0;
foreach (var b in transport)
{
var date = FirstSlash(b);
var cat = b.BillType == BillType.BoardingPass? "登机牌": "火车/机票";
var route = b.FromCity.Length == 0 || b.ToCity.Length == 0? "": $"{b.FromCity}-{b.ToCity}";
if (b.Amount > 0) { transportSub += b.Amount; tripTotal += b.Amount;}
var row = $"<row r=\"{rowIdx}\">"
+ MakeInlineStringCell($"A{rowIdx}", cat, 0)
+ MakeInlineStringCell($"B{rowIdx}", date, 5)
+ (b.Amount > 0
? MakeNumberCell($"C{rowIdx}", b.Amount, 4)
: MakeInlineStringCell($"C{rowIdx}", "-", 5))
+ MakeInlineStringCell($"D{rowIdx}", route, 0)
+ MakeInlineStringCell($"E{rowIdx}", NoteName(b), 0)
+ "</row>";
rows.Add(row);
rowIdx += 1;
}
rows.Add(SubtotalRow(rowIdx, "交通小计", transportSub));
rowIdx += 1;
AddTotal(totals, "交通", transportSub);

// 2. 酒店（同一住宿只计一次。配对以整理时写入的 PairedFolioUID 为准——
//    旧实现在这里按「首个金额相等」另配一遍，一票多住时会把发票再计一次；
//    老清单没有任何配对信息时才回退金额配对。小计行固定骨架：无住宿也出「-」）
var hotelSub = 0.0;
var folioUIDs = new HashSet<string>(hotelFolios.Select(f => f.Uid));
var hasPairingInfo = hotelInvoices.Any(inv => inv.PairedFolioUID.Length > 0);
var folioHasInvoice = new Dictionary<string, bool>();
var standaloneInvoices = new List<BillInfo>();
if (hasPairingInfo)
{
foreach (var folio in hotelFolios)
folioHasInvoice[folio.Uid] = hotelInvoices.Any(inv => inv.PairedFolioUID == folio.Uid);
standaloneInvoices = hotelInvoices.Where(inv =>
!(inv.PairedFolioUID.Length > 0 && folioUIDs.Contains(inv.PairedFolioUID))).ToList();
}
else
{
var used = new HashSet<int>();
foreach (var folio in hotelFolios)
{
var found = false;
for (var i = 0; i < hotelInvoices.Count; i++)
{
if (!used.Contains(i) && Math.Abs(hotelInvoices[i].Amount - folio.Amount) < 0.01)
{
used.Add(i);
found = true;
break;
}
}
folioHasInvoice[folio.Uid] = found;
}
standaloneInvoices = hotelInvoices.Where((_, i) => !used.Contains(i)).ToList();
}
foreach (var folio in hotelFolios)
{
var range = HotelDateRange(folio);
var city = folio.F("city")?? folio.F("hotel_name")?? "";
if (folio.Amount > 0) { hotelSub += folio.Amount; tripTotal += folio.Amount;}
rows.Add(HotelRow(range, city, folio.Amount, folioHasInvoice.TryGetValue(folio.Uid, out var hp) && hp, rowIdx));
rowIdx += 1;
}
foreach (var inv in standaloneInvoices)
{
var range = HotelDateRange(inv);
var city = inv.F("city")?? inv.F("hotel_name")?? "";
if (inv.Amount > 0) { hotelSub += inv.Amount; tripTotal += inv.Amount;}
rows.Add(HotelRow(range, city, inv.Amount, hasInvoice: true, rowIdx));
rowIdx += 1;
}
rows.Add(SubtotalRow(rowIdx, "酒店小计", hotelSub));
rowIdx += 1;
AddTotal(totals, "酒店", hotelSub);

// 3. 滴滴（固定骨架：每段一行汇总，无滴滴时也出「共0段行程 / ?」占位，与样例一致）：
//    发票金额计入；无发票覆盖的行程单金额也计入，避免静默漏钱
{
var didiTotal = 0.0;
// 覆盖按子集和判定（一张汇总发票可覆盖多张行程单），见 DidiCoveredTrips
var coveredTrips = DidiCoveredTrips(
didiInvoice.Select(i => i.Amount).ToList(),
didiTrip.Select(t => t.Amount).ToList());
foreach (var inv in didiInvoice)
{
if (inv.Amount > 0) { didiTotal += inv.Amount; tripTotal += inv.Amount;}
}
for (var ti = 0; ti < didiTrip.Count; ti++)
{
if (!coveredTrips.Contains(ti) && didiTrip[ti].Amount > 0)
{
didiTotal += didiTrip[ti].Amount;
tripTotal += didiTrip[ti].Amount;
}
}
var lastArrival = transport.Count > 0? transport[^1].ToCity: "";
var lastDate = SlashMMDD(trip.LastMMDD);
var arrivalText = lastArrival.Length == 0? "": $"返回{lastArrival}: {lastDate}";
var summaryText = $"行程单{didiTrip.Count}份, 发票{didiInvoice.Count}份";
var periodText = $"共{didiTrip.Count}段行程";
var row = $"<row r=\"{rowIdx}\">"
+ MakeInlineStringCell($"A{rowIdx}", "滴滴出行", 0)
+ MakeInlineStringCell($"B{rowIdx}", periodText, 5)
+ (didiTotal > 0
? MakeNumberCell($"C{rowIdx}", didiTotal, 4)
: MakeInlineStringCell($"C{rowIdx}", "?", 5))
+ MakeInlineStringCell($"D{rowIdx}", arrivalText, 0)
+ MakeInlineStringCell($"E{rowIdx}", summaryText, 0)
+ "</row>";
rows.Add(row);
rowIdx += 1;
AddTotal(totals, "滴滴", didiTotal);
}

// 4. 餐饮
if (dining.Count > 0)
{
var sub = 0.0;
var sorted = dining.OrderBy(b => FirstMMDD(b), StringComparer.Ordinal).ToList();
foreach (var b in sorted)
{
var date = FirstSlash(b);
if (b.Amount > 0) { sub += b.Amount; tripTotal += b.Amount;}
rows.Add(MakeRow(rowIdx, new[]
{
("A", "餐饮", 0),
("B", date, 5),
("C", FmtNumber(b.Amount), 4),
("D", "", 0),
("E", NoteName(b), 0)
}, amountC: b.Amount));
rowIdx += 1;
}
AddTotal(totals, "餐饮", sub);
}

// 5. 其他/兜底（vat 普票、非酒店专票、出租车、通信、other 等）——保证任何票据都出现在明细里
var generic = trip.Bills.Where(IsGenericType).ToList();
if (generic.Count > 0)
{
var sub = 0.0;
var sorted = generic.OrderBy(b => FirstMMDD(b), StringComparer.Ordinal).ToList();
foreach (var b in sorted)
{
if (b.Amount > 0) { sub += b.Amount; tripTotal += b.Amount;}
rows.Add(GenericRow(b, rowIdx));
rowIdx += 1;
}
AddTotal(totals, "其他", sub);
}

// 行程合计（A:E 合并）
var grandText = tripTotal > 0
? $"本段合计: ¥{FmtMoney(tripTotal)}"
: "本段合计: -";
rows.Add(MakeMergedRow(rowIdx, grandText, 9));
merges.Add($"A{rowIdx}:E{rowIdx}");
rowIdx += 1;

return rowIdx;
}

// MARK: - 本地渲染

private static int RenderLocal(
IReadOnlyList<BillInfo> localBills,
int startRow,
List<string> rows,
List<string> merges,
Dictionary<string, double> totals)
{
var rowIdx = startRow;

rows.Add(MakeMergedRow(rowIdx, "【本地费用】", 2));
merges.Add($"A{rowIdx}:E{rowIdx}");
rowIdx += 1;
// 段标题后留一空行（样例版式）
rowIdx += 1;

var telecom = localBills.Where(b => b.BillType == BillType.Telecom).ToList();
var didiTrip = localBills.Where(b => b.BillType == BillType.DidiTrip).ToList();
var didiInvoice = localBills.Where(b => b.BillType == BillType.DidiInvoice).ToList();
var dining = localBills.Where(b => b.BillType == BillType.Dining).ToList();
var vat = localBills.Where(b => b.BillType == BillType.HotelInvoice).ToList();
var localTotal = 0.0;

// 通信（B 列是月份标签「10月」，不是日期）
if (telecom.Count > 0)
{
var sub = 0.0;
foreach (var b in telecom)
{
if (b.Amount > 0) { sub += b.Amount;}
rows.Add(MakeRow(rowIdx, new[]
{
("A", "通信费", 0),
("B", TelecomMonth(b), 5),
("C", FmtNumber(b.Amount), 4),
("D", "", 0),
("E", NoteName(b), 0)
}, amountC: b.Amount));
rowIdx += 1;
}
rows.Add(SubtotalRow(rowIdx, "通信小计", sub));
rowIdx += 1;
AddTotal(totals, "通信", sub);
localTotal += sub;
}

// 滴滴(本地)
if (didiTrip.Count > 0 || didiInvoice.Count > 0)
{
var didiTotal = 0.0;
var coveredTrips = DidiCoveredTrips(
didiInvoice.Select(i => i.Amount).ToList(),
didiTrip.Select(t => t.Amount).ToList());
foreach (var inv in didiInvoice)
{
if (inv.Amount > 0) { didiTotal += inv.Amount;}
}
for (var ti = 0; ti < didiTrip.Count; ti++)
{
if (!coveredTrips.Contains(ti) && didiTrip[ti].Amount > 0)
{
didiTotal += didiTrip[ti].Amount;
}
}
if (didiTotal > 0)
{
rows.Add(MakeRow(rowIdx, new[]
{
("A", "滴滴出行(本地)", 0),
("B", $"共{didiTrip.Count}段", 5),
("C", FmtNumber(didiTotal), 4),
("D", "", 0),
("E", "", 0)
}, amountC: didiTotal));
rowIdx += 1;
AddTotal(totals, "滴滴", didiTotal);
localTotal += didiTotal;
}
}

// 餐饮(本地)
if (dining.Count > 0)
{
var sub = 0.0;
var sorted = dining.OrderBy(b => FirstMMDD(b), StringComparer.Ordinal).ToList();
foreach (var b in sorted)
{
var date = FirstSlash(b);
if (b.Amount > 0) { sub += b.Amount;}
rows.Add(MakeRow(rowIdx, new[]
{
("A", "餐饮", 0),
("B", date, 5),
("C", FmtNumber(b.Amount), 4),
("D", "", 0),
("E", NoteName(b), 0)
}, amountC: b.Amount));
rowIdx += 1;
}
AddTotal(totals, "餐饮", sub);
localTotal += sub;
}

// VAT(本地)
if (vat.Count > 0)
{
var sub = 0.0;
var sorted = vat.OrderBy(b => FirstMMDD(b), StringComparer.Ordinal).ToList();
foreach (var b in sorted)
{
var date = FirstSlash(b);
if (b.Amount > 0) { sub += b.Amount;}
rows.Add(MakeRow(rowIdx, new[]
{
("A", "发票", 0),
("B", date, 5),
("C", FmtNumber(b.Amount), 4),
("D", b.F("seller_name")?? "", 0),
("E", NoteName(b), 0)
}, amountC: b.Amount));
rowIdx += 1;
}
AddTotal(totals, "其他", sub);
localTotal += sub;
}

// 其他/兜底（酒店水单、出租车、加油、通行费、无日期交通票等）——保证不丢
var generic = localBills.Where(b =>!IsLocalSpecificType(b)).ToList();
if (generic.Count > 0)
{
var sub = 0.0;
var sorted = generic.OrderBy(b => FirstMMDD(b), StringComparer.Ordinal).ToList();
foreach (var b in sorted)
{
if (b.Amount > 0) { sub += b.Amount;}
rows.Add(GenericRow(b, rowIdx));
rowIdx += 1;
}
AddTotal(totals, "其他", sub);
localTotal += sub;
}

// 本地合计（A:E 合并）
var localText = localTotal > 0
? $"本地合计: ¥{FmtMoney(localTotal)}"
: "本地合计: -";
rows.Add(MakeMergedRow(rowIdx, localText, 9));
merges.Add($"A{rowIdx}:E{rowIdx}");
rowIdx += 1;

return rowIdx;
}

// MARK: - 总计

private static int RenderGrandTotal(
int startRow,
List<string> rows,
List<string> merges,
Dictionary<string, double> totals)
{
double Get(string key) => totals.TryGetValue(key, out var v)? v: 0;

var grandTotal = totals.Values.Sum();
// 样例格式：分类明细取整数（四舍五入、千分位），如 (交通:1,999  酒店:7,109  …)；
// 与总计的两位小数相加可能差 ±几元，是样例既有口径（与 mac 版一致）
var parts = new List<string>();
if (Get("自驾车") > 0) { parts.Add($"自驾车:{FmtIntGrouped(Get("自驾车"))}"); }
parts.Add($"交通:{FmtIntGrouped(Get("交通"))}");
parts.Add($"酒店:{FmtIntGrouped(Get("酒店"))}");
parts.Add($"滴滴:{FmtIntGrouped(Get("滴滴"))}");
if (Get("餐饮") > 0) { parts.Add($"餐饮:{FmtIntGrouped(Get("餐饮"))}"); }
if (Get("通信") > 0) { parts.Add($"通信:{FmtIntGrouped(Get("通信"))}"); }
if (Get("其他") > 0) { parts.Add($"其他:{FmtIntGrouped(Get("其他"))}"); }

var text = $"报销总计: ¥{FmtMoney(grandTotal)}  ({string.Join("  ", parts)})";
rows.Add(MakeMergedRow(startRow, text, 8));
merges.Add($"A{startRow}:E{startRow}");
return startRow + 1;
}

// MARK: - BillInfo 字段辅助

private static string FirstMMDD(BillInfo b)
{
foreach (var m in b.DateMMDDs)
{
if (m.Length > 0)
return m.Length > 4? m[..4]: m;
}
if (b.DateRange.Start.Length > 0)
{
var s = b.DateRange.Start;
if (s.Length >= 10)
{
return s[^5..].Replace("-", "");
}
}
return "";
}

private static string HotelDateRange(BillInfo b)
{
var s = b.DateRange.Start;
var e = b.DateRange.End;
if (s.Length == 0) return "";
var mmddS = MmddTail(s);
var mmddE = e.Length == 0? mmddS: MmddTail(e);
// 样例写法：09/10-09/12
return mmddS == mmddE? SlashMMDD(mmddS): $"{SlashMMDD(mmddS)}-{SlashMMDD(mmddE)}";
}

/// <summary>取日期串末 5 字符（MM-dd）并去掉 "-"，对应 Swift suffix(5) + replacingOccurrences。</summary>
private static string MmddTail(string s) =>
(s.Length > 5? s[^5..]: s).Replace("-", "");

private static bool IsTransportType(BillType t) =>
t == BillType.TrainTicket || t == BillType.FlightItinerary || t == BillType.BoardingPass;

/// <summary>行程内未被任何具体分类渲染的票据（vat 普票、非酒店专票、出租车、通信、other）。</summary>
private static bool IsGenericType(BillInfo b) => b.BillType switch
{
BillType.TrainTicket or BillType.FlightItinerary or BillType.BoardingPass
or BillType.SelfDriveSheet or BillType.GasInvoice or BillType.TollInvoice
or BillType.HotelFolio or BillType.HotelInvoice
or BillType.DidiTrip or BillType.DidiInvoice or BillType.Dining => false,
BillType.TaxiTransport or BillType.Telecom or BillType.Other => true,
_ => false,
};

/// <summary>本地费用里已被具体分类渲染的票据；其余走兜底。</summary>
private static bool IsLocalSpecificType(BillInfo b) => b.BillType switch
{
BillType.Telecom or BillType.DidiTrip or BillType.DidiInvoice
or BillType.Dining or BillType.HotelInvoice => true,
_ => false,
};

/// <summary>兜底行：类型名 + 日期 + 金额 + 销方/商户名 + 目标文件名。</summary>
private static string GenericRow(BillInfo b, int rowIdx)
{
var cat = b.BillType.DisplayName();
var date = FirstSlash(b);
var seller = b.F("seller_name")?? b.F("merchant_name")?? b.F("hotel_name")?? "";
return $"<row r=\"{rowIdx}\">"
+ MakeInlineStringCell($"A{rowIdx}", cat, 0)
+ MakeInlineStringCell($"B{rowIdx}", date, 5)
+ (b.Amount > 0
? MakeNumberCell($"C{rowIdx}", b.Amount, 4)
: MakeInlineStringCell($"C{rowIdx}", "-", 5))
+ MakeInlineStringCell($"D{rowIdx}", seller, 0)
+ MakeInlineStringCell($"E{rowIdx}", NoteName(b), 0)
+ "</row>";
}

/// <summary>酒店住宿一行：金额只计一次（水单+发票配对时归并到同一住宿）。</summary>
private static string HotelRow(string range, string city, double amount, bool hasInvoice, int rowIdx) =>
$"<row r=\"{rowIdx}\">"
+ MakeInlineStringCell($"A{rowIdx}", "酒店住宿", 0)
+ MakeInlineStringCell($"B{rowIdx}", range, 5)
+ (amount > 0
? MakeNumberCell($"C{rowIdx}", amount, 4)
: MakeInlineStringCell($"C{rowIdx}", "?", 5))
+ MakeInlineStringCell($"D{rowIdx}", city, 0)
+ MakeInlineStringCell($"E{rowIdx}", hasInvoice? "✓": "✗ 缺发票", 0)
+ "</row>";
}
