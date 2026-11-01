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
//  对应 Python core/legacy_excel/gen_excel.py 的输出格式（5 列 + 行程/本地分组）。
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
    """

    // MARK: - sheet1.xml 构建

    /// `xl/worksheets/sheet1.xml`（按平铺 bills 现场分组）
    static func buildSheet(bills: [BillInfo], homeCities: Set<String>) -> String {
        let (trips, localBills) = TripResolver.assignTrips(bills: bills, homeCities: homeCities)
        return buildSheet(trips: trips, localBills: localBills)
    }

    /// `xl/worksheets/sheet1.xml`（用现成的行程分组渲染，与 ZIP 同源）
    static func buildSheet(trips: [TripGroup], localBills: [BillInfo]) -> String {
        var totalsByCategory: [String: Double] = [
            "自驾车": 0, "交通": 0, "酒店": 0, "滴滴": 0, "餐饮": 0, "通信": 0, "其他": 0
        ]

        var rowsXML: [String] = []
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
                                rows: &rowsXML, totals: &totalsByCategory)
        }
        if !localBills.isEmpty {
            rowIdx = renderLocal(localBills, startRow: rowIdx,
                                 rows: &rowsXML, totals: &totalsByCategory)
        }
        _ = renderGrandTotal(startRow: rowIdx, rows: &rowsXML, totals: totalsByCategory)

        let body = rowsXML.joined(separator: "")
        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            + "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
            + "<sheetData>" + body + "</sheetData>"
            + "<pageMargins left=\"0.7\" right=\"0.7\" top=\"0.75\" bottom=\"0.75\" header=\"0.3\" footer=\"0.3\"/>"
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

    // MARK: - 行程渲染

    private static func renderTrip(
        _ trip: TripGroup,
        startRow: Int,
        rows: inout [String],
        totals: inout [String: Double]
    ) -> Int {
        var rowIdx = startRow

        // 行程标题
        rows.append(Self.makeMergedRow(idx: rowIdx, text: "【\(trip.dirname)】", style: 2))
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
                    ("E", b.sourceFile, 0)
                ]
                rows.append(Self.makeRow(idx: rowIdx, cells: cells))
                rowIdx += 1
            }
            var sub: Double = 0
            for b in gas {
                let cat = b.billType == .tollInvoice ? "通行费" : "加油费"
                let date = Self.firstMMDD(b)
                if b.amount > 0 { sub += b.amount; tripTotal += b.amount }
                rows.append(Self.makeRow(idx: rowIdx, cells: [
                    ("A", cat, 0),
                    ("B", date, 5),
                    ("C", Self.fmtNumber(b.amount), 4),
                    ("D", "", 0),
                    ("E", b.sourceFile, 0)
                ], amountC: b.amount))
                rowIdx += 1
            }
            // 拼小计行（C 列用 number cell）：手拼避免 cells 限制
            let subRow = "<row r=\"\(rowIdx)\">"
                + Self.makeInlineStringCell(ref: "A\(rowIdx)", value: "", style: 0)
                + Self.makeInlineStringCell(ref: "B\(rowIdx)", value: "自驾车小计", style: 6)
                + (sub > 0
                    ? Self.makeNumberCell(ref: "C\(rowIdx)", value: sub, style: 3)
                    : Self.makeInlineStringCell(ref: "C\(rowIdx)", value: "-", style: 3))
                + Self.makeInlineStringCell(ref: "D\(rowIdx)", value: "", style: 0)
                + Self.makeInlineStringCell(ref: "E\(rowIdx)", value: "", style: 0)
                + "</row>"
            rows.append(subRow)
            rowIdx += 1
            totals["自驾车", default: 0] += sub
        }

        // 1. 交通
        if !transport.isEmpty {
            rows.append(Self.makeRow(idx: rowIdx, cells: [
                ("A", "铁路交通", 6), ("B", "", 0), ("C", "", 0), ("D", "", 0), ("E", "", 0)
            ]))
            rowIdx += 1
            var sub: Double = 0
            for b in transport {
                let date = Self.firstMMDD(b)
                let cat = b.billType == .boardingPass ? "登机牌" :
                          b.billType == .flightItinerary ? "机票" : "火车"
                let route = b.billType == .boardingPass ? "" : "\(b.fromCity)-\(b.toCity)"
                if b.amount > 0 { sub += b.amount; tripTotal += b.amount }
                // 金额列单独处理
                let row = "<row r=\"\(rowIdx)\">"
                    + Self.makeInlineStringCell(ref: "A\(rowIdx)", value: cat, style: 0)
                    + Self.makeInlineStringCell(ref: "B\(rowIdx)", value: date, style: 5)
                    + (b.amount > 0
                        ? Self.makeNumberCell(ref: "C\(rowIdx)", value: b.amount, style: 4)
                        : Self.makeInlineStringCell(ref: "C\(rowIdx)", value: "-", style: 5))
                    + Self.makeInlineStringCell(ref: "D\(rowIdx)", value: route, style: 0)
                    + Self.makeInlineStringCell(ref: "E\(rowIdx)", value: b.sourceFile, style: 0)
                    + "</row>"
                rows.append(row)
                rowIdx += 1
            }
            // 交通小计
            let subRow = "<row r=\"\(rowIdx)\">"
                + Self.makeInlineStringCell(ref: "A\(rowIdx)", value: "", style: 0)
                + Self.makeInlineStringCell(ref: "B\(rowIdx)", value: "交通小计", style: 6)
                + (sub > 0
                    ? Self.makeNumberCell(ref: "C\(rowIdx)", value: sub, style: 3)
                    : Self.makeInlineStringCell(ref: "C\(rowIdx)", value: "-", style: 3))
                + Self.makeInlineStringCell(ref: "D\(rowIdx)", value: "", style: 0)
                + Self.makeInlineStringCell(ref: "E\(rowIdx)", value: "", style: 0)
                + "</row>"
            rows.append(subRow)
            rowIdx += 1
            totals["交通", default: 0] += sub
        }

        // 2. 酒店（同一住宿只计一次。配对以 finalize 写入的 pairedFolioUID 为准——
        //    旧实现在这里按“首个金额相等”另配一遍，一票多住时会把发票再计一次；
        //    老清单没有任何配对信息时才回退金额配对）
        if !hotelFolios.isEmpty || !hotelInvoices.isEmpty {
            var sub: Double = 0
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
                if folio.amount > 0 { sub += folio.amount; tripTotal += folio.amount }
                rows.append(Self.hotelRow(range: range, city: city, amount: folio.amount, hasInvoice: folioHasInvoice[folio.uid] ?? false, rowIdx: rowIdx))
                rowIdx += 1
            }
            for inv in standaloneInvoices {
                let range = Self.hotelDateRange(inv)
                let city = inv.fields["city"]?.flatMap { $0 } ?? inv.fields["hotel_name"]?.flatMap { $0 } ?? ""
                if inv.amount > 0 { sub += inv.amount; tripTotal += inv.amount }
                rows.append(Self.hotelRow(range: range, city: city, amount: inv.amount, hasInvoice: true, rowIdx: rowIdx))
                rowIdx += 1
            }

            let subRow = "<row r=\"\(rowIdx)\">"
                + Self.makeInlineStringCell(ref: "A\(rowIdx)", value: "", style: 0)
                + Self.makeInlineStringCell(ref: "B\(rowIdx)", value: "酒店小计", style: 6)
                + (sub > 0
                    ? Self.makeNumberCell(ref: "C\(rowIdx)", value: sub, style: 3)
                    : Self.makeInlineStringCell(ref: "C\(rowIdx)", value: "-", style: 3))
                + Self.makeInlineStringCell(ref: "D\(rowIdx)", value: "", style: 0)
                + Self.makeInlineStringCell(ref: "E\(rowIdx)", value: "", style: 0)
                + "</row>"
            rows.append(subRow)
            rowIdx += 1
            totals["酒店", default: 0] += sub
        }

        // 3. 滴滴：发票金额计入；未被发票覆盖的行程单金额也计入，避免静默漏钱。
        //    覆盖按子集和判定（一张汇总发票可覆盖多张行程单），见 didiCoveredTrips
        if !didiTrip.isEmpty || !didiInvoice.isEmpty {
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
            let lastDate = transport.last.map { Self.firstMMDD($0) } ?? ""
            let arrivalText = lastArrival.isEmpty ? "" : "返回\(lastArrival): \(lastDate)"
            let summaryText = "行程单\(didiTrip.count)份, 发票\(didiInvoice.count)份"
            let periodText = "共\(didiTrip.count)段行程"
            let row = "<row r=\"\(rowIdx)\">"
                + Self.makeInlineStringCell(ref: "A\(rowIdx)", value: "滴滴出行", style: 0)
                + Self.makeInlineStringCell(ref: "B\(rowIdx)", value: periodText, style: 5)
                + (didiTotal > 0
                    ? Self.makeNumberCell(ref: "C\(rowIdx)", value: didiTotal, style: 4)
                    : Self.makeInlineStringCell(ref: "C\(rowIdx)", value: "?", style: 5))
                + Self.makeInlineStringCell(ref: "D\(rowIdx)", value: arrivalText, style: 0)
                + Self.makeInlineStringCell(ref: "E\(rowIdx)", value: summaryText, style: 0)
                + "</row>"
            rows.append(row)
            rowIdx += 1
            totals["滴滴", default: 0] += didiTotal
        }

        // 4. 餐饮
        if !dining.isEmpty {
            var sub: Double = 0
            let sorted = dining.sorted { Self.firstMMDD($0) < Self.firstMMDD($1) }
            for b in sorted {
                let date = Self.firstMMDD(b)
                if b.amount > 0 { sub += b.amount; tripTotal += b.amount }
                rows.append(Self.makeRow(idx: rowIdx, cells: [
                    ("A", "餐饮", 0),
                    ("B", date, 5),
                    ("C", Self.fmtNumber(b.amount), 4),
                    ("D", "", 0),
                    ("E", b.sourceFile, 0)
                ], amountC: b.amount))
                rowIdx += 1
            }
            // 餐饮小计（与其余分类对齐，方便人工核对）
            let subRow = "<row r=\"\(rowIdx)\">"
                + Self.makeInlineStringCell(ref: "A\(rowIdx)", value: "", style: 0)
                + Self.makeInlineStringCell(ref: "B\(rowIdx)", value: "餐饮小计", style: 6)
                + (sub > 0
                    ? Self.makeNumberCell(ref: "C\(rowIdx)", value: sub, style: 3)
                    : Self.makeInlineStringCell(ref: "C\(rowIdx)", value: "-", style: 3))
                + Self.makeInlineStringCell(ref: "D\(rowIdx)", value: "", style: 0)
                + Self.makeInlineStringCell(ref: "E\(rowIdx)", value: "", style: 0)
                + "</row>"
            rows.append(subRow)
            rowIdx += 1
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

        // 行程合计
        let grandText = tripTotal > 0
            ? "本段合计: ¥\(Self.fmtNumber(tripTotal))"
            : "本段合计: -"
        rows.append(Self.makeMergedRow(idx: rowIdx, text: grandText, style: 7))
        rowIdx += 1

        return rowIdx
    }

    // MARK: - 本地渲染

    private static func renderLocal(
        _ localBills: [BillInfo],
        startRow: Int,
        rows: inout [String],
        totals: inout [String: Double]
    ) -> Int {
        var rowIdx = startRow

        rows.append(Self.makeMergedRow(idx: rowIdx, text: "【本地费用】", style: 2))
        rowIdx += 1

        let telecom = localBills.filter { $0.billType == .telecom }
        let didiTrip = localBills.filter { $0.billType == .didiTrip }
        let didiInvoice = localBills.filter { $0.billType == .didiInvoice }
        let dining = localBills.filter { $0.billType == .dining }
        let vat = localBills.filter { $0.billType == .hotelInvoice }
        var localTotal: Double = 0

        // 通信
        if !telecom.isEmpty {
            var sub: Double = 0
            for b in telecom {
                let month = Self.firstMMDD(b)
                if b.amount > 0 { sub += b.amount }
                rows.append(Self.makeRow(idx: rowIdx, cells: [
                    ("A", "通信费", 0),
                    ("B", month, 5),
                    ("C", Self.fmtNumber(b.amount), 4),
                    ("D", "", 0),
                    ("E", b.sourceFile, 0)
                ], amountC: b.amount))
                rowIdx += 1
            }
            rows.append(Self.makeRow(idx: rowIdx, cells: [
                ("A", "", 0),
                ("B", "通信小计", 6),
                ("C", Self.fmtNumber(sub), 4),
                ("D", "", 0),
                ("E", "", 0)
            ], amountC: sub))
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
                let date = Self.firstMMDD(b)
                if b.amount > 0 { sub += b.amount }
                rows.append(Self.makeRow(idx: rowIdx, cells: [
                    ("A", "餐饮", 0),
                    ("B", date, 5),
                    ("C", Self.fmtNumber(b.amount), 4),
                    ("D", "", 0),
                    ("E", b.sourceFile, 0)
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
                let date = Self.firstMMDD(b)
                if b.amount > 0 { sub += b.amount }
                rows.append(Self.makeRow(idx: rowIdx, cells: [
                    ("A", "发票", 0),
                    ("B", date, 5),
                    ("C", Self.fmtNumber(b.amount), 4),
                    ("D", b.fields["seller_name"]?.flatMap { $0 } ?? "", 0),
                    ("E", b.sourceFile, 0)
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

        // 本地合计
        let localText = localTotal > 0
            ? "本地合计: ¥\(Self.fmtNumber(localTotal))"
            : "本地合计: -"
        rows.append(Self.makeMergedRow(idx: rowIdx, text: localText, style: 7))
        rowIdx += 1

        return rowIdx
    }

    // MARK: - 总计

    private static func renderGrandTotal(
        startRow: Int,
        rows: inout [String],
        totals: [String: Double]
    ) -> Int {
        let grandTotal = totals.values.reduce(0, +)
        // 分类明细与总计同精度（两位小数）：旧实现用 Int() 截断，括号内相加与总计对不上
        var detail = ""
        if (totals["自驾车"] ?? 0) > 0 { detail += "自驾车:\(Self.fmtNumber(totals["自驾车"] ?? 0))  " }
        detail += "交通:\(Self.fmtNumber(totals["交通"] ?? 0))  酒店:\(Self.fmtNumber(totals["酒店"] ?? 0))  滴滴:\(Self.fmtNumber(totals["滴滴"] ?? 0))"
        if (totals["餐饮"] ?? 0) > 0 { detail += "  餐饮:\(Self.fmtNumber(totals["餐饮"] ?? 0))" }
        if (totals["通信"] ?? 0) > 0 { detail += "  通信:\(Self.fmtNumber(totals["通信"] ?? 0))" }
        if (totals["其他"] ?? 0) > 0 { detail += "  其他:\(Self.fmtNumber(totals["其他"] ?? 0))" }

        let text = "报销总计: ¥\(Self.fmtNumber(grandTotal))  (\(detail))"
        rows.append(Self.makeMergedRow(idx: startRow, text: text, style: 7))
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
        return mmddS == mmddE ? mmddS : "\(mmddS)-\(mmddE)"
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

    /// 兜底行：类型名 + 日期 + 金额 + 销方/商户名 + 原文件名
    private static func genericRow(_ b: BillInfo, _ rowIdx: Int) -> String {
        let cat = b.billType.displayName
        let date = Self.firstMMDD(b)
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
            + Self.makeInlineStringCell(ref: "E\(rowIdx)", value: b.sourceFile, style: 0)
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
