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

    /// 生成 xlsx 文件
    /// - Parameters:
    ///   - bills: 所有 BillInfo
    ///   - outputURL: 输出 .xlsx 路径
    static func build(bills: [BillInfo], outputURL: URL) throws {
        // 1. 构造内存中的所有 XML
        let workbookXML = buildWorkbook()
        let sheetXML = buildSheet(bills: bills)
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

    /// `xl/worksheets/sheet1.xml`
    private static func buildSheet(bills: [BillInfo]) -> String {
        let (trips, localBills) = TripResolver.assignTrips(bills: bills)
        var totalsByCategory: [String: Double] = [
            "自驾车": 0, "交通": 0, "酒店": 0, "滴滴": 0, "餐饮": 0, "通信": 0
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
    private static func makeRow(idx: Int, cells: [(String, String, Int)]) -> String {
        var pieces: [String] = ["<row r=\"\(idx)\">"]
        for (col, value, style) in cells {
            pieces.append(Self.makeInlineStringCell(ref: "\(col)\(idx)", value: value, style: style))
        }
        pieces.append("</row>")
        return pieces.joined()
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
        let hotelInvoices = trip.bills.filter {
            ($0.billType == .hotelInvoice) ||
            ($0.billType == .vatInvoiceSpecial && $0.fields["hotel_name"] != nil)
        }
        let hotels = (hotelFolios + hotelInvoices).sorted { $0.dateRange.start < $1.dateRange.start }
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
                ]))
                rowIdx += 1
            }
            // 小计行（金额单独用 number cell）
            var subCells: [(String, String, Int)] = [
                ("A", "", 0),
                ("B", "自驾车小计", 6),
                ("D", "", 0),
                ("E", "", 0)
            ]
            let subStr = sub > 0 ? Self.fmtNumber(sub) : "-"
            _ = subCells  // placeholder for clarity
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

        // 2. 酒店
        if !hotels.isEmpty {
            var sub: Double = 0
            for b in hotels {
                let range = Self.hotelDateRange(b)
                let city = b.fields["city"]?.flatMap { $0 } ?? b.fields["hotel_name"]?.flatMap { $0 } ?? ""
                let hasInvoice = (b.billType == .hotelInvoice || b.billType == .vatInvoiceSpecial) ? "✓" : "✗ 缺发票"
                if b.amount > 0 { sub += b.amount; tripTotal += b.amount }
                let row = "<row r=\"\(rowIdx)\">"
                    + Self.makeInlineStringCell(ref: "A\(rowIdx)", value: "酒店住宿", style: 0)
                    + Self.makeInlineStringCell(ref: "B\(rowIdx)", value: range, style: 5)
                    + (b.amount > 0
                        ? Self.makeNumberCell(ref: "C\(rowIdx)", value: b.amount, style: 4)
                        : Self.makeInlineStringCell(ref: "C\(rowIdx)", value: "?", style: 5))
                    + Self.makeInlineStringCell(ref: "D\(rowIdx)", value: city, style: 0)
                    + Self.makeInlineStringCell(ref: "E\(rowIdx)", value: hasInvoice, style: 0)
                    + "</row>"
                rows.append(row)
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

        // 3. 滴滴
        if !didiTrip.isEmpty || !didiInvoice.isEmpty {
            var didiTotal: Double = 0
            for inv in didiInvoice {
                if inv.amount > 0 { didiTotal += inv.amount; tripTotal += inv.amount }
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
                ]))
                rowIdx += 1
            }
            totals["餐饮", default: 0] += sub
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
        let vat = localBills.filter {
            [.vatInvoiceGeneral, .vatInvoiceSpecial, .hotelInvoice].contains($0.billType)
        }

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
                ]))
                rowIdx += 1
            }
            rows.append(Self.makeRow(idx: rowIdx, cells: [
                ("A", "", 0),
                ("B", "通信小计", 6),
                ("C", Self.fmtNumber(sub), 4),
                ("D", "", 0),
                ("E", "", 0)
            ]))
            rowIdx += 1
            totals["通信", default: 0] += sub
        }

        // 滴滴(本地)
        if !didiTrip.isEmpty || !didiInvoice.isEmpty {
            var didiTotal: Double = 0
            for inv in didiInvoice {
                if inv.amount > 0 { didiTotal += inv.amount }
            }
            if didiTotal > 0 {
                rows.append(Self.makeRow(idx: rowIdx, cells: [
                    ("A", "滴滴出行(本地)", 0),
                    ("B", "共\(didiTrip.count)段", 5),
                    ("C", Self.fmtNumber(didiTotal), 4),
                    ("D", "", 0),
                    ("E", "", 0)
                ]))
                rowIdx += 1
                totals["滴滴", default: 0] += didiTotal
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
                ]))
                rowIdx += 1
            }
            totals["餐饮", default: 0] += sub
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
                ]))
                rowIdx += 1
            }
            totals["交通", default: 0] += sub
        }

        // 本地合计
        let localTotal = (totals["通信"] ?? 0) + (totals["滴滴"] ?? 0) + (totals["餐饮"] ?? 0)
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
        var detail = ""
        if (totals["自驾车"] ?? 0) > 0 { detail += "自驾车:\(Int(totals["自驾车"] ?? 0))  " }
        detail += "交通:\(Int(totals["交通"] ?? 0))  酒店:\(Int(totals["酒店"] ?? 0))  滴滴:\(Int(totals["滴滴"] ?? 0))"
        if (totals["餐饮"] ?? 0) > 0 { detail += "  餐饮:\(Int(totals["餐饮"] ?? 0))" }
        if (totals["通信"] ?? 0) > 0 { detail += "  通信:\(Int(totals["通信"] ?? 0))" }

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
}
