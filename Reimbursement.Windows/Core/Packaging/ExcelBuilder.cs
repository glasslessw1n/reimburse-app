using System.Globalization;
using System.IO.Compression;
using System.Text;
using Reimbursement.Core.Models;
using Reimbursement.Core.Trips;

namespace Reimbursement.Core.Packaging;

/// <summary>
/// 手写生成 xlsx 报销明细（不依赖第三方库）。对应 Swift ExcelBuilder 的 1:1 移植，
/// 输出格式对应 Python core/legacy_excel/gen_excel.py（5 列 + 行程/本地分组）。
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
<cellXfs count="8">
<xf numFmtId="0" fontId="0" fillId="0" borderId="1" applyAlignment="1"><alignment vertical="center" wrapText="1"/></xf>
<xf numFmtId="0" fontId="1" fillId="5" borderId="1" applyAlignment="1"><alignment horizontal="center" vertical="center" wrapText="1"/></xf>
<xf numFmtId="0" fontId="2" fillId="2" borderId="1" applyAlignment="1"><alignment vertical="center" wrapText="1"/></xf>
<xf numFmtId="0" fontId="4" fillId="3" borderId="1" applyAlignment="1"><alignment horizontal="right" vertical="center"/></xf>
<xf numFmtId="4" fontId="0" fillId="0" borderId="1" applyAlignment="1"><alignment horizontal="right" vertical="center"/></xf>
<xf numFmtId="0" fontId="0" fillId="0" borderId="1" applyAlignment="1"><alignment horizontal="center" vertical="center" wrapText="1"/></xf>
<xf numFmtId="0" fontId="4" fillId="0" borderId="1" applyAlignment="1"><alignment vertical="center"/></xf>
<xf numFmtId="0" fontId="2" fillId="4" borderId="1" applyAlignment="1"><alignment vertical="center"/></xf>
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
rowIdx = RenderTrip(trip, rowIdx, rowsXML, totalsByCategory);
}
if (localBills.Count > 0)
{
rowIdx = RenderLocal(localBills, rowIdx, rowsXML, totalsByCategory);
}
_ = RenderGrandTotal(rowIdx, rowsXML, totalsByCategory);

var body = string.Concat(rowsXML);
return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
+ "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
+ "<sheetData>" + body + "</sheetData>"
+ "<pageMargins left=\"0.7\" right=\"0.7\" top=\"0.75\" bottom=\"0.75\" header=\"0.3\" footer=\"0.3\"/>"
+ "</worksheet>";
}

// MARK: - 行/单元格构建

/// <summary>生成 &lt;row r="idx"&gt;cells&lt;/row&gt;；cells 为 (列字母, 值, style)，值均为字符串（inlineStr）。</summary>
private static string MakeRow(int idx, IReadOnlyList<(string Col, string Value, int Style)> cells)
{
var sb = new StringBuilder();
sb.Append("<row r=\"").Append(idx).Append("\">");
foreach (var (col, value, style) in cells)
{
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
Dictionary<string, double> totals)
{
var rowIdx = startRow;

// 行程标题
rows.Add(MakeMergedRow(rowIdx, $"【{trip.Dirname}】", 2));
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
("E", b.SourceFile, 0)
}));
rowIdx += 1;
}
var sub = 0.0;
foreach (var b in gas)
{
var cat = b.BillType == BillType.TollInvoice? "通行费": "加油费";
var date = FirstMMDD(b);
if (b.Amount > 0) { sub += b.Amount; tripTotal += b.Amount;}
rows.Add(MakeRow(rowIdx, new[]
{
("A", cat, 0),
("B", date, 5),
("C", FmtNumber(b.Amount), 4),
("D", "", 0),
("E", b.SourceFile, 0)
}));
rowIdx += 1;
}
// 拼小计行（C 列用 number cell）：手拼避免 cells 限制
var subRow = $"<row r=\"{rowIdx}\">"
+ MakeInlineStringCell($"A{rowIdx}", "", 0)
+ MakeInlineStringCell($"B{rowIdx}", "自驾车小计", 6)
+ (sub > 0
? MakeNumberCell($"C{rowIdx}", sub, 3)
: MakeInlineStringCell($"C{rowIdx}", "-", 3))
+ MakeInlineStringCell($"D{rowIdx}", "", 0)
+ MakeInlineStringCell($"E{rowIdx}", "", 0)
+ "</row>";
rows.Add(subRow);
rowIdx += 1;
AddTotal(totals, "自驾车", sub);
}

// 1. 交通
if (transport.Count > 0)
{
rows.Add(MakeRow(rowIdx, new[]
{
("A", "铁路交通", 6), ("B", "", 0), ("C", "", 0), ("D", "", 0), ("E", "", 0)
}));
rowIdx += 1;
var sub = 0.0;
foreach (var b in transport)
{
var date = FirstMMDD(b);
var cat = b.BillType == BillType.BoardingPass? "登机牌":
b.BillType == BillType.FlightItinerary? "机票": "火车";
var route = b.BillType == BillType.BoardingPass? "": $"{b.FromCity}-{b.ToCity}";
if (b.Amount > 0) { sub += b.Amount; tripTotal += b.Amount;}
// 金额列单独处理
var row = $"<row r=\"{rowIdx}\">"
+ MakeInlineStringCell($"A{rowIdx}", cat, 0)
+ MakeInlineStringCell($"B{rowIdx}", date, 5)
+ (b.Amount > 0
? MakeNumberCell($"C{rowIdx}", b.Amount, 4)
: MakeInlineStringCell($"C{rowIdx}", "-", 5))
+ MakeInlineStringCell($"D{rowIdx}", route, 0)
+ MakeInlineStringCell($"E{rowIdx}", b.SourceFile, 0)
+ "</row>";
rows.Add(row);
rowIdx += 1;
}
// 交通小计
var subRow = $"<row r=\"{rowIdx}\">"
+ MakeInlineStringCell($"A{rowIdx}", "", 0)
+ MakeInlineStringCell($"B{rowIdx}", "交通小计", 6)
+ (sub > 0
? MakeNumberCell($"C{rowIdx}", sub, 3)
: MakeInlineStringCell($"C{rowIdx}", "-", 3))
+ MakeInlineStringCell($"D{rowIdx}", "", 0)
+ MakeInlineStringCell($"E{rowIdx}", "", 0)
+ "</row>";
rows.Add(subRow);
rowIdx += 1;
AddTotal(totals, "交通", sub);
}

// 2. 酒店（水单+发票按金额配对，同一住宿只计一次，避免重复入表）
if (hotelFolios.Count > 0 || hotelInvoices.Count > 0)
{
var sub = 0.0;
var usedInvoices = new HashSet<int>();

foreach (var folio in hotelFolios)
{
int? matchedIdx = null;
for (var i = 0; i < hotelInvoices.Count; i++)
{
if (!usedInvoices.Contains(i) && Math.Abs(hotelInvoices[i].Amount - folio.Amount) < 0.01)
{
matchedIdx = i;
break;
}
}
var hasInvoice = matchedIdx!= null;
if (matchedIdx is {} mi) usedInvoices.Add(mi);
var range = HotelDateRange(folio);
var city = folio.F("city")?? folio.F("hotel_name")?? "";
if (folio.Amount > 0) { sub += folio.Amount; tripTotal += folio.Amount;}
rows.Add(HotelRow(range, city, folio.Amount, hasInvoice, rowIdx));
rowIdx += 1;
}
for (var i = 0; i < hotelInvoices.Count; i++)
{
if (usedInvoices.Contains(i)) continue;
var inv = hotelInvoices[i];
var range = HotelDateRange(inv);
var city = inv.F("city")?? inv.F("hotel_name")?? "";
if (inv.Amount > 0) { sub += inv.Amount; tripTotal += inv.Amount;}
rows.Add(HotelRow(range, city, inv.Amount, hasInvoice: true, rowIdx));
rowIdx += 1;
}

var subRow = $"<row r=\"{rowIdx}\">"
+ MakeInlineStringCell($"A{rowIdx}", "", 0)
+ MakeInlineStringCell($"B{rowIdx}", "酒店小计", 6)
+ (sub > 0
? MakeNumberCell($"C{rowIdx}", sub, 3)
: MakeInlineStringCell($"C{rowIdx}", "-", 3))
+ MakeInlineStringCell($"D{rowIdx}", "", 0)
+ MakeInlineStringCell($"E{rowIdx}", "", 0)
+ "</row>";
rows.Add(subRow);
rowIdx += 1;
AddTotal(totals, "酒店", sub);
}

// 3. 滴滴：发票金额计入；无发票覆盖的行程单金额也计入，避免静默漏钱
if (didiTrip.Count > 0 || didiInvoice.Count > 0)
{
var didiTotal = 0.0;
var coveredTrips = new HashSet<int>();
foreach (var inv in didiInvoice)
{
if (inv.Amount > 0) { didiTotal += inv.Amount; tripTotal += inv.Amount;}
for (var ti = 0; ti < didiTrip.Count; ti++)
{
if (!coveredTrips.Contains(ti)
&& didiTrip[ti].Amount > 0
&& Math.Abs(didiTrip[ti].Amount - inv.Amount) < 0.01)
{
coveredTrips.Add(ti);
break;
}
}
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
var lastDate = transport.Count > 0? FirstMMDD(transport[^1]): "";
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
var date = FirstMMDD(b);
if (b.Amount > 0) { sub += b.Amount; tripTotal += b.Amount;}
rows.Add(MakeRow(rowIdx, new[]
{
("A", "餐饮", 0),
("B", date, 5),
("C", FmtNumber(b.Amount), 4),
("D", "", 0),
("E", b.SourceFile, 0)
}));
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

// 行程合计
var grandText = tripTotal > 0
? $"本段合计: ¥{FmtNumber(tripTotal)}"
: "本段合计: -";
rows.Add(MakeMergedRow(rowIdx, grandText, 7));
rowIdx += 1;

return rowIdx;
}

// MARK: - 本地渲染

private static int RenderLocal(
IReadOnlyList<BillInfo> localBills,
int startRow,
List<string> rows,
Dictionary<string, double> totals)
{
var rowIdx = startRow;

rows.Add(MakeMergedRow(rowIdx, "【本地费用】", 2));
rowIdx += 1;

var telecom = localBills.Where(b => b.BillType == BillType.Telecom).ToList();
var didiTrip = localBills.Where(b => b.BillType == BillType.DidiTrip).ToList();
var didiInvoice = localBills.Where(b => b.BillType == BillType.DidiInvoice).ToList();
var dining = localBills.Where(b => b.BillType == BillType.Dining).ToList();
var vat = localBills.Where(b => b.BillType == BillType.HotelInvoice).ToList();
var localTotal = 0.0;

// 通信
if (telecom.Count > 0)
{
var sub = 0.0;
foreach (var b in telecom)
{
var month = FirstMMDD(b);
if (b.Amount > 0) { sub += b.Amount;}
rows.Add(MakeRow(rowIdx, new[]
{
("A", "通信费", 0),
("B", month, 5),
("C", FmtNumber(b.Amount), 4),
("D", "", 0),
("E", b.SourceFile, 0)
}));
rowIdx += 1;
}
rows.Add(MakeRow(rowIdx, new[]
{
("A", "", 0),
("B", "通信小计", 6),
("C", FmtNumber(sub), 4),
("D", "", 0),
("E", "", 0)
}));
rowIdx += 1;
AddTotal(totals, "通信", sub);
localTotal += sub;
}

// 滴滴(本地)
if (didiTrip.Count > 0 || didiInvoice.Count > 0)
{
var didiTotal = 0.0;
var coveredTrips = new HashSet<int>();
foreach (var inv in didiInvoice)
{
if (inv.Amount > 0) { didiTotal += inv.Amount;}
for (var ti = 0; ti < didiTrip.Count; ti++)
{
if (!coveredTrips.Contains(ti)
&& didiTrip[ti].Amount > 0
&& Math.Abs(didiTrip[ti].Amount - inv.Amount) < 0.01)
{
coveredTrips.Add(ti);
break;
}
}
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
}));
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
var date = FirstMMDD(b);
if (b.Amount > 0) { sub += b.Amount;}
rows.Add(MakeRow(rowIdx, new[]
{
("A", "餐饮", 0),
("B", date, 5),
("C", FmtNumber(b.Amount), 4),
("D", "", 0),
("E", b.SourceFile, 0)
}));
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
var date = FirstMMDD(b);
if (b.Amount > 0) { sub += b.Amount;}
rows.Add(MakeRow(rowIdx, new[]
{
("A", "发票", 0),
("B", date, 5),
("C", FmtNumber(b.Amount), 4),
("D", b.F("seller_name")?? "", 0),
("E", b.SourceFile, 0)
}));
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

// 本地合计
var localText = localTotal > 0
? $"本地合计: ¥{FmtNumber(localTotal)}"
: "本地合计: -";
rows.Add(MakeMergedRow(rowIdx, localText, 7));
rowIdx += 1;

return rowIdx;
}

// MARK: - 总计

private static int RenderGrandTotal(
int startRow,
List<string> rows,
Dictionary<string, double> totals)
{
double Get(string key) => totals.TryGetValue(key, out var v)? v: 0;

var grandTotal = totals.Values.Sum();
// 分类明细的空格数与 Swift 版逐字一致（段间两个空格，分类数字被 Int 截断——既有行为，照录）
var detail = "";
if (Get("自驾车") > 0) { detail += $"自驾车:{(int)Get("自驾车")}  "; }
detail += $"交通:{(int)Get("交通")}  酒店:{(int)Get("酒店")}  滴滴:{(int)Get("滴滴")}";
if (Get("餐饮") > 0) { detail += $"  餐饮:{(int)Get("餐饮")}"; }
if (Get("通信") > 0) { detail += $"  通信:{(int)Get("通信")}"; }
if (Get("其他") > 0) { detail += $"  其他:{(int)Get("其他")}"; }

var text = $"报销总计: ¥{FmtNumber(grandTotal)} ({detail})";
rows.Add(MakeMergedRow(startRow, text, 7));
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
return mmddS == mmddE? mmddS: $"{mmddS}-{mmddE}";
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

/// <summary>兜底行：类型名 + 日期 + 金额 + 销方/商户名 + 原文件名。</summary>
private static string GenericRow(BillInfo b, int rowIdx)
{
var cat = b.BillType.DisplayName();
var date = FirstMMDD(b);
var seller = b.F("seller_name")?? b.F("merchant_name")?? b.F("hotel_name")?? "";
return $"<row r=\"{rowIdx}\">"
+ MakeInlineStringCell($"A{rowIdx}", cat, 0)
+ MakeInlineStringCell($"B{rowIdx}", date, 5)
+ (b.Amount > 0
? MakeNumberCell($"C{rowIdx}", b.Amount, 4)
: MakeInlineStringCell($"C{rowIdx}", "-", 5))
+ MakeInlineStringCell($"D{rowIdx}", seller, 0)
+ MakeInlineStringCell($"E{rowIdx}", b.SourceFile, 0)
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
