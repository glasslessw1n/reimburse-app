//
//  ExcelBuilder.swift
//  报销整理Native
//
//  手写生成 xlsx 报销明细（不依赖第三方库）。
//
//  xlsx 实际上是 zip 包含多个 XML 文件。我们：
//  1. 在临时目录里写所有 XML
//  2. 用 /usr/bin/zip 打包成 .xlsx
//
//  版式以用户 2026-11-09 提供的目标样例（0910-1026.xlsx）为准：5 列、行程/本地
//  分段、每段固定骨架（铁路交通标签 + 交通小计、酒店小计、滴滴汇总行）、日期用
//  MM/DD、备注列写整理后的目标文件名、总计行带分类整数明细。金额口径（酒店
//  一票一计、滴滴子集和覆盖、自驾行程单不计）与整合 PDF 保持一致。
//

import Foundation

enum ExcelBuilder {

    /// 生成 xlsx 文件（按平铺 bills 现场分组；无 finalize 结果时用）
    static func build(bills: [BillInfo], homeCities: Set<String>, outputURL: URL) throws {
        try writeXLSX(sheetXML: buildSheet(bills: bills, homeCities: homeCities), outputURL: outputURL)
    }

    /// 生成 xlsx 文件（直接用 manifest 里 finalize 好的 trips/local，与 ZIP 内容同源，
    /// 避免 Excel 再跑一遍分组导致两侧行程划分不一致）
    static func build(trips: [TripGroup], local: [BillInfo], outputURL: URL) throws {
        try writeXLSX(sheetXML: buildSheet(trips: trips, localBills: local), outputURL: outputURL)
    }

    private static func writeXLSX(sheetXML: String, outputURL: URL) throws {
        // 1. 构造内存中的所有 XML
        let workbookXML = buildWorkbook()
        let stylesXML = Self.stylesXML

        // 2. 临时目录写所有 XML 文件
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("xlsx_" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try Self.createDir(at: tmp, sub: "_rels")
        try Self.createDir(at: tmp, sub: "xl")
        try Self.createDir(at: tmp, sub: "xl/_rels")
        try Self.createDir(at: tmp, sub: "xl/worksheets")

        try Self.writeFile(at: tmp.appendingPathComponent("[Content_Types].xml"),
                           content: Self.contentTypesXML)
        try Self.writeFile(at: tmp.appendingPathComponent("_rels/.rels"),
                           content: Self.rootRelsXML)
        try Self.writeFile(at: tmp.appendingPathComponent("xl/workbook.xml"),
                           content: workbookXML)
        try Self.writeFile(at: tmp.appendingPathComponent("xl/_rels/workbook.xml.rels"),
                           content: Self.workbookRelsXML)
        try Self.writeFile(at: tmp.appendingPathComponent("xl/worksheets/sheet1.xml"),
                           content: sheetXML)
        try Self.writeFile(at: tmp.appendingPathComponent("xl/styles.xml"),
                           content: stylesXML)

        // 3. zip 打包
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        task.arguments = ["-r", "-X", "-q", outputURL.path, "."]
        task.currentDirectoryURL = tmp
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            throw ExcelError.zipFailed(task.terminationStatus)
        }
    }

    enum ExcelError: LocalizedError {
        case zipFailed(Int32)
        var errorDescription: String? {
            switch self {
            case .zipFailed(let s): return "zip exit \(s)"
            }
        }
    }

    // MARK: - 文件工具

    private static func createDir(at base: URL, sub: String) throws {
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent(sub),
            withIntermediateDirectories: true)
    }

    private static func writeFile(at url: URL, content: String) throws {
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func xmlEscape(_ s: String) -> String {
        return s
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - 静态 XML 模板

    /// `[Content_Types].xml`
    private static let contentTypesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
      <Default Extension="xml" ContentType="application/xml"/>
      <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
      <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
      <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
    </Types>
    """

    /// `_rels/.rels`
    private static let rootRelsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
    </Relationships>
    """

    /// `xl/workbook.xml`
    private static func buildWorkbook() -> String {
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
                  xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <sheets>
            <sheet name="报销明细" sheetId="1" r:id="rId1"/>
          </sheets>
        </workbook>
        """
    }

    /// `xl/_rels/workbook.xml.rels`
    private static let workbookRelsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
      <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
    </Relationships>
    """

    /// `xl/styles.xml`
    private static let stylesXML = """
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
    """

    // MARK: - sheet1.xml 构建

    /// `xl/worksheets/sheet1.xml`（按平铺 bills 现场分组）
    static func buildSheet(bills: [BillInfo], homeCities: Set<String>) -> String {
        let (trips, localBills) = TripResolver.assignTrips(bills: bills, homeCities: homeCities)
        return buildSheet(trips: trips, localBills: localBills)
    }

    /// `xl/worksheets/sheet1.xml`（用现成的行程分组渲染，与 ZIP 同源）
    /// 版式以用户提供的目标样例（0910-1026.xlsx）为准：列宽 14/18/12/30/24、
    /// 首行冻结、自动筛选、段标题/合计行 A:E 合并、总计行前留一空行。
    static func buildSheet(trips: [TripGroup], localBills: [BillInfo]) -> String {
        var totalsByCategory: [String: Double] = [
            "自驾车": 0, "交通": 0, "酒店": 0, "滴滴": 0, "餐饮": 0, "通信": 0, "其他": 0
        ]

        var rowsXML: [String] = []
        var merges: [String] = []
        // 表头
        rowsXML.append(Self.makeRow(idx: 1, cells: [
            ("A", "票据类别", 1),
            ("B", "日期/区间", 1),
            ("C", "金额(¥)", 1),
            ("D", "明细", 1),
            ("E", "备注", 1)
        ]))
        var rowIdx = 2

        for trip in trips {
            rowIdx = renderTrip(trip, startRow: rowIdx,
                                rows: &rowsXML, merges: &merges, totals: &totalsByCategory)
        }
        if !localBills.isEmpty {
            rowIdx = renderLocal(localBills, startRow: rowIdx,
                                 rows: &rowsXML, merges: &merges, totals: &totalsByCategory)
        }
        // 总计行前留一空行（样例版式）：只推进计数、不出行元素
        rowIdx += 1
        let nextRow = renderGrandTotal(startRow: rowIdx, rows: &rowsXML, merges: &merges, totals: totalsByCategory)
        let lastRow = nextRow - 1

        let body = rowsXML.joined(separator: "")
        let mergeXML = merges.isEmpty ? "" :
            "<mergeCells count=\"\(merges.count)\">"
            + merges.map { "<mergeCell ref=\"\($0)\"/>" }.joined()
            + "</mergeCells>"
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
            + "<autoFilter ref=\"A1:E\(lastRow)\"/>"
            + mergeXML
            + "<pageMargins left=\"0.7\" right=\"0.7\" top=\"0.75\" bottom=\"0.75\" header=\"0.3\" footer=\"0.3\"/>"
            + "<pageSetup orientation=\"landscape\"/>"
            + "</worksheet>"
    }

    // MARK: - 行/单元格构建（避免 template literal 嵌套）

    /// 生成 <row r="idx">cells</row>
    /// cells: [(列字母, 值, style)] —— 值是 String
    /// amountC 非 nil 时，C 列改写数值单元格（财务可用 SUM 再加工；纯文本金额不参与计算）
    private static func makeRow(idx: Int, cells: [(String, String, Int)], amountC: Double? = nil) -> String {
        var pieces: [String] = ["<row r=\"\(idx)\">"]
        for (col, value, style) in cells {
            if col == "C", let amount = amountC {
                pieces.append(Self.makeNumberCell(ref: "\(col)\(idx)", value: amount, style: style))
            } else {
                pieces.append(Self.makeInlineStringCell(ref: "\(col)\(idx)", value: value, style: style))
            }
        }
        pieces.append("</row>")
        return pieces.joined()
    }

    /// 滴滴覆盖判定：一张发票可覆盖若干张行程单（金额之和相等），返回被覆盖的行程单下标集合。
    /// 旧实现只认“单张金额恰好相等”，汇总发票（一张盖多段）覆盖不了任何单张，
    /// 发票金额与全部行程单金额会被重复计入。按分（整数）做子集和匹配避免浮点误差；
    /// 候选按金额降序带剪枝回溯，节点上限兜底（超限时宁可少覆盖，不错覆盖）。
    static func didiCoveredTrips(invoiceAmounts: [Double], tripAmounts: [Double]) -> Set<Int> {
        func cents(_ v: Double) -> Int { Int((v * 100).rounded()) }
        var remaining = tripAmounts.indices.filter { tripAmounts[$0] > 0 }
        var covered = Set<Int>()
        for inv in invoiceAmounts where inv > 0 {
            let target = cents(inv)
            guard target > 0 else { continue }
            let candidates = remaining.sorted { tripAmounts[$0] > tripAmounts[$1] }
            var chosen: [Int] = []
            var nodes = 0
            func search(_ pos: Int, _ sum: Int) -> Bool {
                if sum == target { return true }
                if sum > target || pos >= candidates.count { return false }
                nodes += 1
                if nodes > 20000 { return false }
                let idx = candidates[pos]
                chosen.append(idx)
                if search(pos + 1, sum + cents(tripAmounts[idx])) { return true }
                chosen.removeLast()
                return search(pos + 1, sum)
            }
            if search(0, 0) {
                covered.formUnion(chosen)
                let chosenSet = Set(chosen)
                remaining.removeAll { chosenSet.contains($0) }
            }
        }
        return covered
    }

    /// 数字单元格
    private static func makeNumberCell(ref: String, value: Double, style: Int) -> String {
        return "<c r=\"\(ref)\" s=\"\(style)\"><v>\(Self.fmtNumber(value))</v></c>"
    }

    /// inline 字符串单元格（避免 sharedStrings.xml）
    private static func makeInlineStringCell(ref: String, value: String, style: Int) -> String {
        return "<c r=\"\(ref)\" s=\"\(style)\" t=\"inlineStr\"><is><t>\(Self.xmlEscape(value))</t></is></c>"
    }

    /// 合并行（5 列合并成 1 列文本）
    private static func makeMergedRow(idx: Int, text: String, style: Int) -> String {
        let escaped = Self.xmlEscape(text)
        return "<row r=\"\(idx)\"><c r=\"A\(idx)\" s=\"\(style)\" t=\"inlineStr\"><is><t>\(escaped)</t></is></c></row>"
    }

    private static func fmtNumber(_ v: Double) -> String {
        return String(format: "%.2f", v)
    }

    /// 千分位 + 两位小数（合计/总计的金额文本用，如 1,703.50）
    private static func fmtMoney(_ v: Double) -> String {
        groupThousands(fmtNumber(v))
    }

    /// 四舍五入到整数 + 千分位（总计行分类明细用，如 1,999）
    private static func fmtIntGrouped(_ v: Double) -> String {
        groupThousands(String(Int(v.rounded())))
    }

    private static func groupThousands(_ s: String) -> String {
        var intPart = s
        var frac = ""
        if let dot = s.firstIndex(of: ".") {
            intPart = String(s[..<dot])
            frac = String(s[dot...])
        }
        var out = ""
        for (i, ch) in intPart.reversed().enumerated() {
            if i > 0, i % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return String(out.reversed()) + frac
    }

    /// MMDD → MM/DD（样例的日期写法）
    private static func slashMMDD(_ mmdd: String) -> String {
        guard mmdd.count == 4 else { return mmdd }
        return "\(mmdd.prefix(2))/\(mmdd.suffix(2))"
    }

    /// 票据首日期（MM/DD 形式）
    private static func firstSlash(_ b: BillInfo) -> String {
        slashMMDD(firstMMDD(b))
    }

    /// 备注列文件名：优先整理后的目标文件名（与 ZIP 包内一致），未整理时回退原文件名
    private static func noteName(_ b: BillInfo) -> String {
        b.targetFilename.isEmpty ? b.sourceFile : b.targetFilename
    }

    /// 通信费月份标签：month 字段（YYYY-MM）→「10月」；缺失时用日期月份
    private static func telecomMonth(_ b: BillInfo) -> String {
        if let m = b.fields["month"]?.flatMap({ $0 }), m.count >= 7 {
            let mm = String(m.dropFirst(5).prefix(2))
            return "\(Int(mm) ?? 0)月"
        }
        let s = b.dateRange.start
        if s.count >= 7 {
            let mm = String(s.dropFirst(5).prefix(2))
            return "\(Int(mm) ?? 0)月"
        }
        return ""
    }

    /// 小计行（样例版式：只有 B 标签 + C 金额两格，A/D/E 不出单元格）
    private static func subtotalRow(idx: Int, label: String, amount: Double) -> String {
        "<row r=\"\(idx)\">"
            + Self.makeInlineStringCell(ref: "B\(idx)", value: label, style: 11)
            + (amount > 0
                ? Self.makeNumberCell(ref: "C\(idx)", value: amount, style: 10)
                : Self.makeInlineStringCell(ref: "C\(idx)", value: "-", style: 3))
            + "</row>"
    }

    // MARK: - 行程渲染

    private static func renderTrip(
        _ trip: TripGroup,
        startRow: Int,
        rows: inout [String],
        merges: inout [String],
        totals: inout [String: Double]
    ) -> Int {
        var rowIdx = startRow

        // 行程标题（A:E 合并）
        rows.append(Self.makeMergedRow(idx: rowIdx, text: "【\(trip.dirname)】", style: 2))
        merges.append("A\(rowIdx):E\(rowIdx)")
        rowIdx += 1

        // 分类
        let transport = trip.bills.filter { Self.isTransportType($0.billType) }
            .sorted { Self.firstMMDD($0) < Self.firstMMDD($1) }
        let selfDrive = trip.bills.filter { $0.billType == .selfDriveSheet }
        let hotelFolios = trip.bills.filter { $0.billType == .hotelFolio }
            .sorted { $0.dateRange.start < $1.dateRange.start }
        let hotelInvoices = trip.bills.filter { $0.billType == .hotelInvoice }
            .sorted { $0.dateRange.start < $1.dateRange.start }
        let didiTrip = trip.bills.filter { $0.billType == .didiTrip }
        let didiInvoice = trip.bills.filter { $0.billType == .didiInvoice }
        let dining = trip.bills.filter { $0.billType == .dining }
        let gas = trip.bills.filter { $0.billType == .gasInvoice || $0.billType == .tollInvoice }

        var tripTotal: Double = 0

        // 0. 自驾车 + 加油 + 通行费
        if !selfDrive.isEmpty || !gas.isEmpty {
            for b in selfDrive {
                let route = "\(b.fromCity)-\(b.toCity)"
                let cells: [(String, String, Int)] = [
                    ("A", "自驾车行程单", 0),
                    ("B", "-", 5),
                    ("C", "-", 5),
                    ("D", route, 0),
                    ("E", Self.noteName(b), 0)
                ]
                rows.append(Self.makeRow(idx: rowIdx, cells: cells))
                rowIdx += 1
            }
            var sub: Double = 0
            for b in gas {
                let cat = b.billType == .tollInvoice ? "通行费" : "加油费"
                let date = Self.firstSlash(b)
                if b.amount > 0 { sub += b.amount; tripTotal += b.amount }
                rows.append(Self.makeRow(idx: rowIdx, cells: [
                    ("A", cat, 0),
                    ("B", date, 5),
                    ("C", Self.fmtNumber(b.amount), 4),
                    ("D", "", 0),
                    ("E", Self.noteName(b), 0)
                ], amountC: b.amount))
                rowIdx += 1
            }
            rows.append(Self.subtotalRow(idx: rowIdx, label: "自驾车小计", amount: sub))
            rowIdx += 1
            totals["自驾车", default: 0] += sub
        }

        // 1. 交通（固定骨架：标签行 + 票据行 + 小计，无票据时也出小计「-」）
        //    标签行只有 A 一格；类别名：登机牌 / 火车/机票（火车票与机票行程单同名）
        rows.append("<row r=\"\(rowIdx)\">"
            + Self.makeInlineStringCell(ref: "A\(rowIdx)", value: "铁路交通", style: 6)
            + "</row>")
        rowIdx += 1
        var transportSub: Double = 0
        for b in transport {
            let date = Self.firstSlash(b)
            let cat = b.billType == .boardingPass ? "登机牌" : "火车/机票"
            let route = (b.fromCity.isEmpty || b.toCity.isEmpty) ? "" : "\(b.fromCity)-\(b.toCity)"
            if b.amount > 0 { transportSub += b.amount; tripTotal += b.amount }
            let row = "<row r=\"\(rowIdx)\">"
                + Self.makeInlineStringCell(ref: "A\(rowIdx)", value: cat, style: 0)
                + Self.makeInlineStringCell(ref: "B\(rowIdx)", value: date, style: 5)
                + (b.amount > 0
                    ? Self.makeNumberCell(ref: "C\(rowIdx)", value: b.amount, style: 4)
                    : Self.makeInlineStringCell(ref: "C\(rowIdx)", value: "-", style: 5))
                + Self.makeInlineStringCell(ref: "D\(rowIdx)", value: route, style: 0)
                + Self.makeInlineStringCell(ref: "E\(rowIdx)", value: Self.noteName(b), style: 0)
                + "</row>"
            rows.append(row)
            rowIdx += 1
        }
        rows.append(Self.subtotalRow(idx: rowIdx, label: "交通小计", amount: transportSub))
        rowIdx += 1
        totals["交通", default: 0] += transportSub

        // 2. 酒店（同一住宿只计一次。配对以 finalize 写入的 pairedFolioUID 为准——
        //    旧实现在这里按“首个金额相等”另配一遍，一票多住时会把发票再计一次；
        //    老清单没有任何配对信息时才回退金额配对。小计行固定骨架：无住宿也出「-」）
        var hotelSub: Double = 0
        let folioUIDs = Set(hotelFolios.map { $0.uid })
        let hasPairingInfo = hotelInvoices.contains { $0.pairedFolioUID != nil }
        var folioHasInvoice: [String: Bool] = [:]
        var standaloneInvoices: [BillInfo] = []
        if hasPairingInfo {
            for folio in hotelFolios {
                folioHasInvoice[folio.uid] = hotelInvoices.contains { $0.pairedFolioUID == folio.uid }
            }
            standaloneInvoices = hotelInvoices.filter { inv in
                !(inv.pairedFolioUID.map { folioUIDs.contains($0) } ?? false)
            }
        } else {
            var used = Set<Int>()
            for folio in hotelFolios {
                if let i = hotelInvoices.indices.first(where: { i in
                    !used.contains(i) && abs(hotelInvoices[i].amount - folio.amount) < 0.01
                }) {
                    used.insert(i)
                    folioHasInvoice[folio.uid] = true
                } else {
                    folioHasInvoice[folio.uid] = false
                }
            }
            standaloneInvoices = hotelInvoices.indices.filter { !used.contains($0) }.map { hotelInvoices[$0] }
        }

        for folio in hotelFolios {
            let range = Self.hotelDateRange(folio)
            let city = folio.fields["city"]?.flatMap { $0 } ?? folio.fields["hotel_name"]?.flatMap { $0 } ?? ""
            if folio.amount > 0 { hotelSub += folio.amount; tripTotal += folio.amount }
            rows.append(Self.hotelRow(range: range, city: city, amount: folio.amount, hasInvoice: folioHasInvoice[folio.uid] ?? false, rowIdx: rowIdx))
            rowIdx += 1
        }
        for inv in standaloneInvoices {
            let range = Self.hotelDateRange(inv)
            let city = inv.fields["city"]?.flatMap { $0 } ?? inv.fields["hotel_name"]?.flatMap { $0 } ?? ""
            if inv.amount > 0 { hotelSub += inv.amount; tripTotal += inv.amount }
            rows.append(Self.hotelRow(range: range, city: city, amount: inv.amount, hasInvoice: true, rowIdx: rowIdx))
            rowIdx += 1
        }
        rows.append(Self.subtotalRow(idx: rowIdx, label: "酒店小计", amount: hotelSub))
        rowIdx += 1
        totals["酒店", default: 0] += hotelSub

        // 3. 滴滴（固定骨架：每段一行汇总，无滴滴时也出「共0段行程 / ?」占位，与样例一致）：
        //    发票金额计入；未被发票覆盖的行程单金额也计入，避免静默漏钱。
        //    覆盖按子集和判定（一张汇总发票可覆盖多张行程单），见 didiCoveredTrips
        var didiTotal: Double = 0
        let coveredTrips = Self.didiCoveredTrips(
            invoiceAmounts: didiInvoice.map { $0.amount },
            tripAmounts: didiTrip.map { $0.amount })
        for inv in didiInvoice where inv.amount > 0 {
            didiTotal += inv.amount; tripTotal += inv.amount
        }
        for ti in didiTrip.indices where !coveredTrips.contains(ti) && didiTrip[ti].amount > 0 {
            didiTotal += didiTrip[ti].amount
            tripTotal += didiTrip[ti].amount
        }
        let lastArrival = transport.last?.toCity ?? ""
        let lastDate = slashMMDD(trip.lastMMDD)
        let arrivalText = lastArrival.isEmpty ? "" : "返回\(lastArrival): \(lastDate)"
        let summaryText = "行程单\(didiTrip.count)份, 发票\(didiInvoice.count)份"
        let periodText = "共\(didiTrip.count)段行程"
        let didiRow = "<row r=\"\(rowIdx)\">"
            + Self.makeInlineStringCell(ref: "A\(rowIdx)", value: "滴滴出行", style: 0)
            + Self.makeInlineStringCell(ref: "B\(rowIdx)", value: periodText, style: 5)
            + (didiTotal > 0
                ? Self.makeNumberCell(ref: "C\(rowIdx)", value: didiTotal, style: 4)
                : Self.makeInlineStringCell(ref: "C\(rowIdx)", value: "?", style: 5))
            + Self.makeInlineStringCell(ref: "D\(rowIdx)", value: arrivalText, style: 0)
            + Self.makeInlineStringCell(ref: "E\(rowIdx)", value: summaryText, style: 0)
            + "</row>"
        rows.append(didiRow)
        rowIdx += 1
        totals["滴滴", default: 0] += didiTotal

        // 4. 餐饮（样例版式：只出票据行，不出小计——金额直接进本段合计）
        if !dining.isEmpty {
            var sub: Double = 0
            let sorted = dining.sorted { Self.firstMMDD($0) < Self.firstMMDD($1) }
            for b in sorted {
                let date = Self.firstSlash(b)
                if b.amount > 0 { sub += b.amount; tripTotal += b.amount }
                rows.append(Self.makeRow(idx: rowIdx, cells: [
                    ("A", "餐饮", 0),
                    ("B", date, 5),
                    ("C", Self.fmtNumber(b.amount), 4),
                    ("D", "", 0),
                    ("E", Self.noteName(b), 0)
                ], amountC: b.amount))
                rowIdx += 1
            }
            totals["餐饮", default: 0] += sub
        }

        // 5. 其他/兜底（vat 普票、非酒店专票、出租车、通信、other 等）——保证任何票据都出现在明细里
        let generic = trip.bills.filter { Self.isGenericType($0) }
        if !generic.isEmpty {
            var sub: Double = 0
            let sorted = generic.sorted { Self.firstMMDD($0) < Self.firstMMDD($1) }
            for b in sorted {
                if b.amount > 0 { sub += b.amount; tripTotal += b.amount }
                rows.append(Self.genericRow(b, rowIdx))
                rowIdx += 1
            }
            totals["其他", default: 0] += sub
        }

        // 行程合计（A:E 合并）
        let grandText = tripTotal > 0
            ? "本段合计: ¥\(Self.fmtMoney(tripTotal))"
            : "本段合计: -"
        rows.append(Self.makeMergedRow(idx: rowIdx, text: grandText, style: 9))
        merges.append("A\(rowIdx):E\(rowIdx)")
        rowIdx += 1

        return rowIdx
    }

    // MARK: - 本地渲染

    private static func renderLocal(
        _ localBills: [BillInfo],
        startRow: Int,
        rows: inout [String],
        merges: inout [String],
        totals: inout [String: Double]
    ) -> Int {
        var rowIdx = startRow

        rows.append(Self.makeMergedRow(idx: rowIdx, text: "【本地费用】", style: 2))
        merges.append("A\(rowIdx):E\(rowIdx)")
        rowIdx += 1
        // 段标题后留一空行（样例版式）
        rowIdx += 1

        let telecom = localBills.filter { $0.billType == .telecom }
        let didiTrip = localBills.filter { $0.billType == .didiTrip }
        let didiInvoice = localBills.filter { $0.billType == .didiInvoice }
        let dining = localBills.filter { $0.billType == .dining }
        let vat = localBills.filter { $0.billType == .hotelInvoice }
        var localTotal: Double = 0

        // 通信（B 列是月份标签「10月」，不是日期）
        if !telecom.isEmpty {
            var sub: Double = 0
            for b in telecom {
                if b.amount > 0 { sub += b.amount }
                rows.append(Self.makeRow(idx: rowIdx, cells: [
                    ("A", "通信费", 0),
                    ("B", Self.telecomMonth(b), 5),
                    ("C", Self.fmtNumber(b.amount), 4),
                    ("D", "", 0),
                    ("E", Self.noteName(b), 0)
                ], amountC: b.amount))
                rowIdx += 1
            }
            rows.append(Self.subtotalRow(idx: rowIdx, label: "通信小计", amount: sub))
            rowIdx += 1
            totals["通信", default: 0] += sub
            localTotal += sub
        }

        // 滴滴(本地)（覆盖判定与行程段同一套子集和逻辑）
        if !didiTrip.isEmpty || !didiInvoice.isEmpty {
            var didiTotal: Double = 0
            let coveredTrips = Self.didiCoveredTrips(
                invoiceAmounts: didiInvoice.map { $0.amount },
                tripAmounts: didiTrip.map { $0.amount })
            for inv in didiInvoice where inv.amount > 0 {
                didiTotal += inv.amount
            }
            for ti in didiTrip.indices where !coveredTrips.contains(ti) && didiTrip[ti].amount > 0 {
                didiTotal += didiTrip[ti].amount
            }
            if didiTotal > 0 {
                rows.append(Self.makeRow(idx: rowIdx, cells: [
                    ("A", "滴滴出行(本地)", 0),
                    ("B", "共\(didiTrip.count)段", 5),
                    ("C", Self.fmtNumber(didiTotal), 4),
                    ("D", "", 0),
                    ("E", "", 0)
                ], amountC: didiTotal))
                rowIdx += 1
                totals["滴滴", default: 0] += didiTotal
                localTotal += didiTotal
            }
        }

        // 餐饮(本地)
        if !dining.isEmpty {
            var sub: Double = 0
            let sorted = dining.sorted { Self.firstMMDD($0) < Self.firstMMDD($1) }
            for b in sorted {
                let date = Self.firstSlash(b)
                if b.amount > 0 { sub += b.amount }
                rows.append(Self.makeRow(idx: rowIdx, cells: [
                    ("A", "餐饮", 0),
                    ("B", date, 5),
                    ("C", Self.fmtNumber(b.amount), 4),
                    ("D", "", 0),
                    ("E", Self.noteName(b), 0)
                ], amountC: b.amount))
                rowIdx += 1
            }
            totals["餐饮", default: 0] += sub
            localTotal += sub
        }

        // VAT(本地)
        if !vat.isEmpty {
            var sub: Double = 0
            let sorted = vat.sorted { Self.firstMMDD($0) < Self.firstMMDD($1) }
            for b in sorted {
                let date = Self.firstSlash(b)
                if b.amount > 0 { sub += b.amount }
                rows.append(Self.makeRow(idx: rowIdx, cells: [
                    ("A", "发票", 0),
                    ("B", date, 5),
                    ("C", Self.fmtNumber(b.amount), 4),
                    ("D", b.fields["seller_name"]?.flatMap { $0 } ?? "", 0),
                    ("E", Self.noteName(b), 0)
                ], amountC: b.amount))
                rowIdx += 1
            }
            totals["其他", default: 0] += sub
            localTotal += sub
        }

        // 其他/兜底（酒店水单、出租车、加油、通行费、无日期交通票等）——保证不丢
        let generic = localBills.filter { !Self.isLocalSpecificType($0) }
        if !generic.isEmpty {
            var sub: Double = 0
            let sorted = generic.sorted { Self.firstMMDD($0) < Self.firstMMDD($1) }
            for b in sorted {
                if b.amount > 0 { sub += b.amount }
                rows.append(Self.genericRow(b, rowIdx))
                rowIdx += 1
            }
            totals["其他", default: 0] += sub
            localTotal += sub
        }

        // 本地合计（A:E 合并）
        let localText = localTotal > 0
            ? "本地合计: ¥\(Self.fmtMoney(localTotal))"
            : "本地合计: -"
        rows.append(Self.makeMergedRow(idx: rowIdx, text: localText, style: 9))
        merges.append("A\(rowIdx):E\(rowIdx)")
        rowIdx += 1

        return rowIdx
    }

    // MARK: - 总计

    private static func renderGrandTotal(
        startRow: Int,
        rows: inout [String],
        merges: inout [String],
        totals: [String: Double]
    ) -> Int {
        let grandTotal = totals.values.reduce(0, +)
        // 样例格式：分类明细取整数（四舍五入、千分位），如 (交通:1,999  酒店:7,109  …)；
        // 与总计的两位小数相加可能差 ±几元，是样例既有口径
        var parts: [String] = []
        if (totals["自驾车"] ?? 0) > 0 { parts.append("自驾车:\(Self.fmtIntGrouped(totals["自驾车"] ?? 0))") }
        parts.append("交通:\(Self.fmtIntGrouped(totals["交通"] ?? 0))")
        parts.append("酒店:\(Self.fmtIntGrouped(totals["酒店"] ?? 0))")
        parts.append("滴滴:\(Self.fmtIntGrouped(totals["滴滴"] ?? 0))")
        if (totals["餐饮"] ?? 0) > 0 { parts.append("餐饮:\(Self.fmtIntGrouped(totals["餐饮"] ?? 0))") }
        if (totals["通信"] ?? 0) > 0 { parts.append("通信:\(Self.fmtIntGrouped(totals["通信"] ?? 0))") }
        if (totals["其他"] ?? 0) > 0 { parts.append("其他:\(Self.fmtIntGrouped(totals["其他"] ?? 0))") }

        let text = "报销总计: ¥\(Self.fmtMoney(grandTotal))  (\(parts.joined(separator: "  ")))"
        rows.append(Self.makeMergedRow(idx: startRow, text: text, style: 8))
        merges.append("A\(startRow):E\(startRow)")
        return startRow + 1
    }

    // MARK: - BillInfo 字段辅助

    private static func firstMMDD(_ b: BillInfo) -> String {
        if let m = b.dateMMDDs.first(where: { !$0.isEmpty }) {
            return String(m.prefix(4))
        }
        if !b.dateRange.start.isEmpty {
            let s = b.dateRange.start
            if s.count >= 10 {
                return String(s.suffix(5).prefix(5)).replacingOccurrences(of: "-", with: "")
            }
        }
        return ""
    }

    private static func hotelDateRange(_ b: BillInfo) -> String {
        let s = b.dateRange.start
        let e = b.dateRange.end
        guard !s.isEmpty else { return "" }
        let mmddS = String(s.suffix(5).prefix(5)).replacingOccurrences(of: "-", with: "")
        let mmddE = e.isEmpty ? mmddS : String(e.suffix(5).prefix(5)).replacingOccurrences(of: "-", with: "")
        // 样例写法：09/10-09/12
        return mmddS == mmddE ? slashMMDD(mmddS) : "\(slashMMDD(mmddS))-\(slashMMDD(mmddE))"
    }

    private static func isTransportType(_ t: BillType) -> Bool {
        return t == .trainTicket || t == .flightItinerary || t == .boardingPass
    }

    /// 行程内未被任何具体分类渲染的票据（vat 普票、非酒店专票、出租车、通信、other）
    private static func isGenericType(_ b: BillInfo) -> Bool {
        switch b.billType {
        case .trainTicket, .flightItinerary, .boardingPass,
             .selfDriveSheet, .gasInvoice, .tollInvoice,
             .hotelFolio, .hotelInvoice,
             .didiTrip, .didiInvoice, .dining:
            return false
        case .taxiTransport, .telecom, .other:
            return true
        }
    }

    /// 本地费用里已被具体分类渲染的票据；其余走兜底
    private static func isLocalSpecificType(_ b: BillInfo) -> Bool {
        switch b.billType {
        case .telecom, .didiTrip, .didiInvoice, .dining, .hotelInvoice:
            return true
        default:
            return false
        }
    }

    /// 兜底行：类型名 + 日期 + 金额 + 销方/商户名 + 目标文件名
    private static func genericRow(_ b: BillInfo, _ rowIdx: Int) -> String {
        let cat = b.billType.displayName
        let date = Self.firstSlash(b)
        let seller = b.fields["seller_name"]?.flatMap { $0 }
            ?? b.fields["merchant_name"]?.flatMap { $0 }
            ?? b.fields["hotel_name"]?.flatMap { $0 }
            ?? ""
        return "<row r=\"\(rowIdx)\">"
            + Self.makeInlineStringCell(ref: "A\(rowIdx)", value: cat, style: 0)
            + Self.makeInlineStringCell(ref: "B\(rowIdx)", value: date, style: 5)
            + (b.amount > 0
                ? Self.makeNumberCell(ref: "C\(rowIdx)", value: b.amount, style: 4)
                : Self.makeInlineStringCell(ref: "C\(rowIdx)", value: "-", style: 5))
            + Self.makeInlineStringCell(ref: "D\(rowIdx)", value: seller, style: 0)
            + Self.makeInlineStringCell(ref: "E\(rowIdx)", value: Self.noteName(b), style: 0)
            + "</row>"
    }

    /// 酒店住宿一行：金额只计一次（水单+发票配对时归并到同一住宿）
    private static func hotelRow(range: String, city: String, amount: Double, hasInvoice: Bool, rowIdx: Int) -> String {
        "<row r=\"\(rowIdx)\">"
            + Self.makeInlineStringCell(ref: "A\(rowIdx)", value: "酒店住宿", style: 0)
            + Self.makeInlineStringCell(ref: "B\(rowIdx)", value: range, style: 5)
            + (amount > 0
                ? Self.makeNumberCell(ref: "C\(rowIdx)", value: amount, style: 4)
                : Self.makeInlineStringCell(ref: "C\(rowIdx)", value: "?", style: 5))
            + Self.makeInlineStringCell(ref: "D\(rowIdx)", value: city, style: 0)
            + Self.makeInlineStringCell(ref: "E\(rowIdx)", value: hasInvoice ? "✓" : "✗ 缺发票", style: 0)
            + "</row>"
    }
}
