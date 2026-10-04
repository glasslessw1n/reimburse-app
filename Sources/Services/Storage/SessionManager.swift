//
//  SessionManager.swift
//  报销整理Native
//
//  Session 生命周期管理：create → ingest → finalize → clear → list。
//  对应 core/collector.py:create_session / ingest_file / finalize_session / list_session_files。
//
//  数据落地：
//  ~/Library/Application Support/Reimbursement/
//    ├── .env                         （LLM 配置）
//    └── sessions/
//        └── {sid}/
//            ├── manifest.json
//            ├── originals/{filename}    原文件
//            └── trips/                  finalize 后填
//

import Foundation

@MainActor
final class SessionManager: ObservableObject {
    @Published var manifest: SessionManifest

    let sid: String
    let rootDir: URL

    init(sid: String) {
        self.sid = sid
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
            .appendingPathComponent("Reimbursement", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(sid, isDirectory: true)
        self.rootDir = appSupport

        // 加载或创建 manifest
        let manifestURL = appSupport.appendingPathComponent("manifest.json")
        if let data = try? Data(contentsOf: manifestURL),
           let m = try? JSONDecoder().decode(SessionManifest.self, from: data) {
            self.manifest = m
        } else {
            self.manifest = SessionManifest(
                sid: sid,
                createdAt: ISO8601DateFormatter().string(from: Date()),
                ocrAvailable: true,
                llmAvailable: false  // M6 设置面板更新
            )
            try? FileManager.default.createDirectory(
                at: appSupport.appendingPathComponent("originals"),
                withIntermediateDirectories: true
            )
            save()
        }
    }

    // MARK: - 写入

    /// 把原始文件写到 originals/
    func saveOriginal(data: Data, filename: String) throws -> URL {
        let safe = filename.replacingOccurrences(of: "/", with: "_")
        let url = rootDir.appendingPathComponent("originals").appendingPathComponent(safe)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// 追加一张识别后的票据
    /// 通用去重：按 (billType + date_range + from_city + to_city + 关键 fields) 生成 dedup key，
    /// 同一物理凭证的 OCR/LLM 重复识别只保留先来那一张（保留 confidence 高的）。
    func ingest(_ bill: BillInfo) {
        let billKey = Self.dedupKey(of: bill)
        if let dupIdx = manifest.bills.firstIndex(where: { Self.dedupKey(of: $0) == billKey }) {
            if bill.confidence > manifest.bills[dupIdx].confidence {
                manifest.bills[dupIdx] = bill
                save()
            }
            return
        }
        manifest.bills.append(bill)
        if bill.needsReview { manifest.needsReviewCount += 1 }
        save()
    }

    /// 通用 dedup key：类型 + 日期范围 + 起降城市 + 关键 fields
    /// OCR/LLM 可能让一张票产出略不同的 fields（如 date_mmdds 长度不同），
    /// 用 JSON 化 fields 比较最稳。
    /// hotel_folio / hotel_invoice 还会因 amount 配对产生多张，dedup key 含 amount 区分。
    private static func dedupKey(of bill: BillInfo) -> String {
        var canonicalFields = bill.fields
        // 去空、order 无关（fields 是 dict）
        let amountKey = String(format: "%.2f", bill.amount)
        let flightNo = canonicalFields["flight_no"]?.flatMap { $0 } ?? ""
        let passenger = canonicalFields["passenger_name"]?.flatMap { $0 } ?? ""
        let roomNo = canonicalFields["room_no"]?.flatMap { $0 } ?? ""
        let invoiceNo = canonicalFields["invoice_no"]?.flatMap { $0 } ?? ""
        return "\(bill.billType.rawValue)|\(bill.dateRange.start)_\(bill.dateRange.end)|\(bill.fromCity)>\(bill.toCity)|\(amountKey)|\(flightNo)|\(passenger)|\(roomNo)|\(invoiceNo)"
    }

    /// finalize：完整流程（对应 core/collector.py:finalize_session）
    /// 1. hotel invoice ↔ folio match（房号/金额/酒店名相似度）+ enrich 回填
    /// 2. didi_trip 按时间顺序分配字母 A/B/C
    /// 3. didi_invoice 按金额匹配已有 didi_trip 字母
    /// 4. toll_invoice 顺序分配数字序号
    /// 5. TripResolver.assignTrips 行程归类
    /// 6. 给所有 bill 填 targetSubdir/targetFilename
    func finalize() {
        var bills = manifest.bills

        // ── 1. hotel invoice ↔ folio match ──
        Self.matchAndEnrichHotel(bills: &bills)

        // ── 2/3. didi 字母分配（每个 trip 内部 / local 内部各自分配） ──
        // TripResolver 之前需要 bills 上的 didiLetter 字段已就绪，但 TripResolver 不看 didiLetter；
        // 所以 didi 字母在 TripResolver 之后、文件 move 之前分配也可以。
        // 这里先做 hotel match，trip 分配留给后面。

        // ── 5. 行程归类 ──
        // 注入 EXCLUDE_CITIES（常驻地）到 TripResolver，作为切分依据
        let homeCitiesRaw = ProcessInfo.processInfo.environment["EXCLUDE_CITIES"] ?? ""
        let homeCities = homeCitiesRaw
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        TripResolver.setHomeCities(homeCities)

        var (trips, local) = TripResolver.assignTrips(bills: bills)
        // ── 2/3/4. 字母/序号分配（在 trip/local 容器内部做，确保每个 trip 内独立）──
        for i in 0..<trips.count { Self.assignSequences(in: &trips[i].bills) }
        Self.assignSequences(in: &local)

        // 给所有 bill 设 targetSubdir
        for ti in 0..<trips.count {
            let dirname = trips[ti].dirname
            for bi in 0..<trips[ti].bills.count {
                trips[ti].bills[bi].targetSubdir = dirname
                // hotel match 后的 finalTargetName 优先（已是 enrich 后的新名字）
                let baseName = trips[ti].bills[bi].finalTargetName.isEmpty
                    ? Self.buildFilename(for: trips[ti].bills[bi])
                    : trips[ti].bills[bi].finalTargetName
                trips[ti].bills[bi].targetFilename = baseName
            }
        }
        for i in 0..<local.count {
            local[i].targetSubdir = "本地"
            let baseName = local[i].finalTargetName.isEmpty
                ? Self.buildFilename(for: local[i])
                : local[i].finalTargetName
            local[i].targetFilename = baseName
        }

        // 同步回 manifest
        manifest.trips = trips
        manifest.local = local
        // 把更新后的 bill 写回 manifest（inout 已变，但 bills 是 var 局部；这里重置 manifest.bills）
        manifest.bills = trips.flatMap { $0.bills } + local

        save()
    }

    // MARK: - hotel match + enrich

    /// 酒店水单 ↔ 发票匹配
    ///
    /// 规则（按用户确认）：
    /// 1. **金额完全相等**（0.01 容差）是唯一判定依据
    /// 2. 匹配范围：水单 vs 所有发票（vat_*/hotel_invoice）
    /// 3. 匹配成功后，发票**借用**水单的日期范围 + 城市 + hotel_name，按 hotel 命名
    /// 4. 没匹配上的发票保持原 vat 命名
    private static func matchAndEnrichHotel(bills: inout [BillInfo]) {
        var folioIdxs: [Int] = []
        var invoiceIdxs: [Int] = []
        for (i, b) in bills.enumerated() {
            if b.billType == .hotelFolio { folioIdxs.append(i) }
            // 任何 vat/hotel 发票都可能配对
            switch b.billType {
            case .vatInvoiceGeneral, .vatInvoiceSpecial, .hotelInvoice:
                invoiceIdxs.append(i)
            default:
                break
            }
        }
        guard !folioIdxs.isEmpty, !invoiceIdxs.isEmpty else { return }

        var usedFolios = Set<Int>()

        for iIdx in invoiceIdxs {
            var inv = bills[iIdx]
            guard inv.amount > 0 else { continue }
            for fIdx in folioIdxs where !usedFolios.contains(fIdx) {
                guard bills[fIdx].amount > 0 else { continue }
                if abs(inv.amount - bills[fIdx].amount) < 0.01 {
                    enrich(invoice: &inv, folio: &bills[fIdx])
                    bills[iIdx] = inv  // 写回
                    usedFolios.insert(fIdx)
                    break
                }
            }
        }
    }

    /// 发票缺失字段用水单回填（不覆盖已有值）+ 日期偏移检测
    /// 同时把 invoice 的 issue_date + nights 信息反向修 folio 的 date_range（folio 的 LLM 经常漏）
    private static func enrich(invoice: inout BillInfo, folio: inout BillInfo) {
        let fi = folio.fields

        // 1) 日期范围（invoice 从 folio 补）
        if invoice.dateRange.start.isEmpty ||
           invoice.dateRange.start == invoice.dateRange.end {
            if !folio.dateRange.start.isEmpty {
                invoice.dateRange = folio.dateRange
                invoice.fields["check_in_date"] = folio.dateRange.start
                invoice.fields["check_out_date"] = folio.dateRange.end.isEmpty ? folio.dateRange.start : folio.dateRange.end
            }
        }
        // 1b) folio 的 date_range 用 invoice 的 issue_date 修正（hotel folio LLM 经常把 issue 当 check_in）
        let issueDate = invoice.fields["issue_date"]?.flatMap({ $0 })
        if let issueDate = issueDate, issueDate.count >= 10,
           TripResolver.mmddFromDateString(folio.dateRange.start).count == 4 {
            let folioFirst = TripResolver.mmddFromDateString(folio.dateRange.start)
            let issueMMDD = TripResolver.mmddFromDateString(issueDate)
            // folio 的 check_out_date 缺失/不可信 → 用 invoice 的 issue_date
            if folio.dateRange.end.isEmpty || folio.dateRange.end == folio.dateRange.start {
                // folio 单日 → 推断为 check_in + nights
                if let nights = fi["nights"]?.flatMap({ Int($0) }), nights > 0,
                   let checkInMMDD = shiftMMDDBackward(issueMMDD, days: nights - 1) {
                    folio.dateRange.start = mmddToDateString(checkInMMDD)
                    folio.dateRange.end = mmddToDateString(issueMMDD)
                    folio.fields["check_in_date"] = folio.dateRange.start
                    folio.fields["check_out_date"] = folio.dateRange.end
                } else {
                    // 没有 nights 信息 → 用 folio.start 推断为 check_in
                    folio.fields["check_out_date"] = issueDate
                    folio.dateRange.end = issueDate
                }
            }
        }

        // 2) 晚数（invoice 从 folio 补）
        if (invoice.fields["nights"]?.flatMap { $0 } ?? "").isEmpty {
            if let n = fi["nights"]?.flatMap({ $0 }) { invoice.fields["nights"] = n }
        }
        // 2b) folio 的 nights 从 invoice 推断（nights = issue_date - check_in_date + 1）
        if (fi["nights"]?.flatMap({ $0 }) ?? "").isEmpty {
            if let checkIn = fi["check_in_date"]?.flatMap({ $0 }),
               let issue = invoice.fields["issue_date"]?.flatMap({ $0 }),
               checkIn.count >= 10, issue.count >= 10 {
                let nights = Self.diffDays(from: checkIn, to: issue) + 1
                if nights > 0, nights < 30 {
                    folio.fields["nights"] = String(nights)
                }
            }
        }

        // 3) 城市：invoice.city 为空时从 folio 补
        if invoice.cities.isEmpty, !folio.cities.isEmpty {
            invoice.cities = folio.cities
        }

        // 4) 房号/客人姓名/房型/酒店名
        for k in ["room_no", "guest_name", "room_type", "hotel_name"] {
            if (invoice.fields[k]?.flatMap { $0 } ?? "").isEmpty {
                if let v = fi[k]?.flatMap({ $0 }) { invoice.fields[k] = v }
            }
        }
        // 5) 品牌
        if (invoice.fields["brand"]?.flatMap { $0 } ?? "").isEmpty {
            if let v = fi["brand"]?.flatMap({ $0 }) { invoice.fields["brand"] = v }
        }

        // 6) 反向修：folio 的 city 可能是 LLM 误把"客人地址"当成酒店城市
        //    如果 invoice.city 真实且与 folio.city 不同 → 用 invoice.city 修 folio
        let folioCity = folio.fields["city"]?.flatMap { $0 } ?? ""
        let invoiceCity = invoice.fields["city"]?.flatMap { $0 } ?? ""
        if !invoiceCity.isEmpty, !folioCity.isEmpty,
           invoiceCity != folioCity {
            folio.fields["city"] = invoiceCity
            folio.cities = [invoiceCity]
        }

        // 6) 日期偏移检测
        let ci = invoice.fields["check_in_date"]?.flatMap { $0 } ?? ""
        let co = invoice.fields["check_out_date"]?.flatMap { $0 } ?? ""
        let issue = invoice.fields["issue_date"]?.flatMap { $0 } ?? ""
        if !ci.isEmpty && ci.count >= 10, !issue.isEmpty && issue.count >= 10 {
            let ciD = Self.parseYMD(ci), issueD = Self.parseYMD(issue)
            let coD = co.count >= 10 ? Self.parseYMD(co) : nil
            if let ciD = ciD, let issueD = issueD {
                let diffCI = abs(Self.dayDiff(ciD, issueD))
                let diffCO = coD.map { abs(Self.dayDiff($0, issueD)) }
                let minDiff = [diffCI, diffCO].compactMap { $0 }.min() ?? diffCI
                if minDiff > 1 {
                    invoice.needsReview = true
                    let warn = "水单住 \(ci)~\(co) 与发票开具 \(issue) 最近相差 \(minDiff) 天"
                    invoice.reviewReason = invoice.reviewReason.isEmpty ? "日期偏移，\(warn)" : "\(invoice.reviewReason)；\(warn)"
                }
            }
        }

        // 7) match 成功后：用 folio 的日期范围 + 城市生成最终文件名（覆盖发票的 targetFilename）
        let newName = Self.buildFilename(for: invoice)
        if newName != invoice.targetFilename {
            invoice.finalTargetName = newName
        }
    }

    /// 简单字符级相似度（Python difflib.SequenceMatcher 简化版）
    private static func simpleSimilarity(_ a: String, _ b: String) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let aChars = Array(a)
        let bChars = Array(b)
        var lcs: [[Int]] = Array(repeating: Array(repeating: 0, count: bChars.count + 1), count: aChars.count + 1)
        for i in 0..<aChars.count {
            for j in 0..<bChars.count {
                if aChars[i] == bChars[j] {
                    lcs[i+1][j+1] = lcs[i][j] + 1
                } else {
                    lcs[i+1][j+1] = max(lcs[i+1][j], lcs[i][j+1])
                }
            }
        }
        let lcsLen = lcs[aChars.count][bChars.count]
        let maxLen = Double(max(aChars.count, bChars.count))
        return Double(lcsLen) / maxLen
    }

    private static func parseYMD(_ s: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: String(s.prefix(10)))
    }

    private static func dayDiff(_ a: Date, _ b: Date) -> Int {
        let cal = Calendar(identifier: .gregorian)
        return cal.dateComponents([.day], from: a, to: b).day ?? 0
    }

    // MARK: - didi 字母分配 + toll 序号

    private static func assignSequences(in container: inout [BillInfo]) {
        var usedLetters = Set<String>()
        var nextLetter = "A"
        func nextAvailableLetter() -> String {
            while usedLetters.contains(nextLetter) {
                let scalar = nextLetter.unicodeScalars.first!.value
                nextLetter = String(UnicodeScalar(scalar + 1)!)
            }
            let r = nextLetter
            usedLetters.insert(r)
            let scalar = nextLetter.unicodeScalars.first!.value
            nextLetter = String(UnicodeScalar(scalar + 1)!)
            return r
        }

        // 1) didi_trip：按原始顺序（A/B/C...）
        for i in 0..<container.count where container[i].billType == .didiTrip {
            if !container[i].didiLetter.isEmpty && usedLetters.contains(container[i].didiLetter) {
                container[i].didiLetter = nextAvailableLetter()
            } else if !container[i].didiLetter.isEmpty {
                usedLetters.insert(container[i].didiLetter)
            } else {
                container[i].didiLetter = nextAvailableLetter()
            }
        }

        // 2) didi_invoice：按金额匹配已有 didi_trip
        var matchedTripIdxs = Set<Int>()
        for i in 0..<container.count where container[i].billType == .didiInvoice {
            var matchedLetter = ""
            if container[i].amount > 0 {
                for j in 0..<container.count
                where container[j].billType == .didiTrip && !matchedTripIdxs.contains(j) {
                    if container[j].amount > 0, abs(container[j].amount - container[i].amount) < 0.01 {
                        matchedLetter = container[j].didiLetter
                        matchedTripIdxs.insert(j)
                        break
                    }
                }
            }
            container[i].didiLetter = matchedLetter.isEmpty ? nextAvailableLetter() : matchedLetter
        }

        // 3) toll_invoice：顺序分配数字序号
        var tollSeq = 1
        for i in 0..<container.count where container[i].billType == .tollInvoice {
            container[i].didiLetter = String(format: "%02d", tollSeq)
            tollSeq += 1
        }
    }

    /// 清空整个 session
    func clear() throws {
        try FileManager.default.removeItem(at: rootDir)
    }

    /// 持久化 manifest
    func save() {
        let url = rootDir.appendingPathComponent("manifest.json")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(manifest) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - 文件名生成

    /// 对应 core/collector.py:_build_filename
    /// 按 BillType 分支生成规范化文件名。
    /// 示例：
    ///   火车票       "0303 北京-上海 553"
    ///   机票行程单   "0303 CA1234 北京-上海 1436.51"
    ///   滴滴行程单   "滴滴出行行程报销单A"
    ///   滴滴电子发票 "滴滴电子发票A"
    ///   酒店水单     "0303-0305 上海 住宿水单"
    ///   VAT 普票     "2026-03-15 北京 XX公司 1436.51"
    ///   兜底         "0303 1436.51"
    @MainActor
    static func buildFilename(for bill: BillInfo) -> String {
        let suf = ".pdf"
        let bt = bill.billType
        let f = bill.fields

        // 第一个非空的 MMDD
        var dateMmdd = ""
        for d in bill.dateMMDDs where !d.isEmpty {
            let s = String(d.prefix(4))
            if s.count == 4 { dateMmdd = s; break }
        }
        if dateMmdd.isEmpty {
            // 退化：issue_date / check_in_date / departure_date → MMDD
            for fk in ["issue_date", "check_in_date", "departure_date"] {
                let v = f[fk].flatMap { $0 } ?? ""
                if v.count >= 10 {
                    dateMmdd = String(v.dropFirst(5).prefix(2)) + String(v.dropFirst(8).prefix(2))
                    break
                }
            }
        }

        let fmtAmount = Self.fmtAmount(bill.amount)
        let route = (bill.fromCity.isEmpty || bill.toCity.isEmpty) ? "" : "\(bill.fromCity)-\(bill.toCity)"
        let issueDate = f["issue_date"].flatMap { $0 } ?? ""

        switch bt {
        case .trainTicket:
            let parts = [dateMmdd, route, fmtAmount].filter { !$0.isEmpty }
            return parts.isEmpty ? "火车票\(dateMmdd)\(suf)" : parts.joined(separator: " ") + suf

        case .flightItinerary:
            let flightNo = f["flight_no"].flatMap { $0 } ?? ""
            let parts = [dateMmdd, flightNo, route, fmtAmount].filter { !$0.isEmpty }
            return parts.isEmpty ? "机票行程单\(suf)" : parts.joined(separator: " ") + suf

        case .boardingPass:
            // MMDD 起始-到达 登机牌.pdf（不要航班号）
            let parts = [dateMmdd, route, "登机牌"].filter { !$0.isEmpty }
            return parts.isEmpty ? "登机牌\(suf)" : parts.joined(separator: " ") + suf

        case .selfDriveSheet:
            let body = ["高速路行程单", dateMmdd, route].filter { !$0.isEmpty }.joined(separator: " ")
            return body + suf

        case .didiTrip:
            let letter = bill.didiLetter.isEmpty ? "X" : bill.didiLetter
            return "滴滴出行行程报销单\(letter)\(suf)"

        case .didiInvoice:
            let letter = bill.didiLetter.isEmpty ? "X" : bill.didiLetter
            return "滴滴电子发票\(letter)\(suf)"

        case .hotelFolio, .hotelInvoice:
            // 任何 hotel 命名的发票（直接识别为 hotel 类型 / 或 enrich 后走 hotel）都走这里
            let s = bill.dateRange.start
            let e = bill.dateRange.end
            // city 优先级：fields.city > info.cities[0] > 从 seller_name 正则提取 > "未知"
            var city = f["city"].flatMap { $0 } ?? ""
            if city.isEmpty, let c0 = bill.cities.first { city = c0 }
            if city.isEmpty {
                let seller = f["seller_name"].flatMap { $0 } ?? f["hotel_name"].flatMap { $0 } ?? ""
                city = Self.extractHotelCity(from: seller) ?? String(seller.prefix(4))
            }
            if city.isEmpty { city = "未知" }

            // 日期 + 城市 + 住宿水单/发票
            // 例：`0827-0829 桂林住宿水单.pdf`（日期后 1 个空格；城市和后缀拼成一个 token）
            let dateSeg: String
            if !s.isEmpty && !e.isEmpty && s != e {
                dateSeg = "\(Self.mmdd(s))-\(Self.mmdd(e))"
            } else {
                dateSeg = !s.isEmpty ? Self.mmdd(s) : dateMmdd
            }
            let suffixWord = bt == .hotelFolio ? "住宿水单" : "住宿发票"
            if dateSeg.isEmpty {
                return "\(city)\(suffixWord)\(suf)"
            }
            return "\(dateSeg) \(city)\(suffixWord)\(suf)"

        case .taxiTransport:
            let parts = [dateMmdd, "出租车发票", fmtAmount].filter { !$0.isEmpty }
            return parts.isEmpty ? "出租车\(suf)" : parts.joined(separator: " ") + suf

        case .gasInvoice:
            let parts = [dateMmdd, "加油费", fmtAmount].filter { !$0.isEmpty }
            return parts.isEmpty ? "加油费\(suf)" : parts.joined(separator: " ") + suf

        case .tollInvoice:
            let seq = bill.didiLetter.isEmpty ? "01" : bill.didiLetter
            let parts = [dateMmdd, "通行费\(seq)", fmtAmount].filter { !$0.isEmpty }
            return parts.isEmpty ? "通行费\(suf)" : parts.joined(separator: " ") + suf

        case .dining:
            // 日期 + 城市餐饮发票 + 金额：城市和"餐饮发票"拼成一个 token
            // 例：`0315 北京餐饮发票 580.pdf`
            let city = (f["city"].flatMap { $0 } ?? bill.cities.first ?? "")
            let cityDining = city.isEmpty ? "餐饮发票" : "\(city)餐饮发票"
            let parts = [dateMmdd, cityDining, fmtAmount].filter { !$0.isEmpty }
            return parts.isEmpty ? "餐饮\(suf)" : parts.joined(separator: " ") + suf

        case .telecom:
            let parts = [dateMmdd, "通信发票", fmtAmount].filter { !$0.isEmpty }
            return parts.isEmpty ? "通信\(suf)" : parts.joined(separator: " ") + suf
            // 注：通信发票字段固定，单独一段可以保持空格；如要 token 合并改成 [dateMmdd, "通信发票\(fmtAmount)"].joined(...)

        case .vatInvoiceGeneral, .vatInvoiceSpecial:
            // 酒店开的 VAT 专票：只要有 check_in_date 或 hotel_name 字段就按 hotel 命名
            let hotelName = f["hotel_name"].flatMap { $0 } ?? ""
            let checkIn = f["check_in_date"].flatMap { $0 } ?? ""
            if !hotelName.isEmpty || !checkIn.isEmpty {
                return Self.buildHotelInvoiceFilename(bill: bill, f: f, dateMmdd: dateMmdd)
            }
            // 普通 VAT：YYYY-MM-DD 城市销方 金额.pdf
            let city = (f["city"].flatMap { $0 } ?? bill.cities.first ?? "")
            let issueYmd = !issueDate.isEmpty && issueDate.count >= 10
                ? String(issueDate.prefix(10))
                : dateMmdd
            // 城市 + 销方简写合成一个 token（中间不空格）
            // 兜底顺序：seller_name > hotel_name（hotel invoice 经常 LLM 把它填成 hotel_name）
            let sellerName = f["seller_name"].flatMap { $0 } ?? f["hotel_name"].flatMap { $0 } ?? ""
            let citySeller = [city, Self.shortSeller(sellerName)]
                .filter { !$0.isEmpty }
                .joined(separator: "")
            let parts = [issueYmd, citySeller, fmtAmount].filter { !$0.isEmpty }
            return parts.isEmpty ? "发票\(suf)" : parts.joined(separator: " ") + suf

        case .other:
            let parts = [dateMmdd, fmtAmount].filter { !$0.isEmpty }
            if !parts.isEmpty { return parts.joined(separator: " ") + suf }
            // 兜底：原文件名 stem
            let stem = (bill.sourceFile as NSString).deletingPathExtension
            return stem.isEmpty ? "其他\(suf)" : "\(stem)\(suf)"
        }
    }

    // MARK: - 文件名工具

    /// 金额格式化：整数去 .00（239.00 → "239"；239.50 → "239.50"）
    private static func fmtAmount(_ amount: Double) -> String {
        guard amount > 0 else { return "" }
        var s = String(format: "%.2f", amount)
        if s.contains(".") {
            s = s.replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
            s = s.replacingOccurrences(of: "\\.$", with: "", options: .regularExpression)
        }
        return s.isEmpty ? "0" : s
    }

    /// 销方名简化：去 "管理有限公司" / "有限公司" / "有限责任公司" / "公司" / "集团"，限 14 字
    private static func shortSeller(_ name: String?) -> String {
        var n = (name ?? "").trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return "" }
        let suffixes = ["管理有限公司", "有限公司", "有限责任公司", "公司", "集团"]
        for s in suffixes where n.hasSuffix(s) {
            n = String(n.dropLast(s.count))
            break
        }
        return String(n.prefix(14))
    }

    /// 从酒店全名提取城市：`"上海外滩茂悦大酒店"` → "上海"
    private static func extractHotelCity(from seller: String) -> String? {
        guard !seller.isEmpty else { return nil }
        // 匹配 "2-3 字城市" + 可选字 + "酒店/饭店"
        let pattern = "([\\u4e00-\\u9fa5]{2,3}(?:[\\u4e00-\\u9fa5]{0,2})?(?:酒店|饭店))"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(seller.startIndex..., in: seller)
        if let m = regex.firstMatch(in: seller, range: range), let r = Range(m.range(at: 1), in: seller) {
            var s = String(seller[r])
            s = s.replacingOccurrences(of: "酒店", with: "")
            s = s.replacingOccurrences(of: "饭店", with: "")
            return s
        }
        return nil
    }

    /// YYYY-MM-DD → MMDD
    private static func mmdd(_ s: String) -> String {
        guard s.count >= 10 else { return s }
        return String(s.dropFirst(5).prefix(2)) + String(s.dropFirst(8).prefix(2))
    }

    /// 复用 hotel 发票命名逻辑（VAT 专票但实际是酒店开的）
    private static func buildHotelInvoiceFilename(bill: BillInfo, f: [String: String?], dateMmdd: String) -> String {
        let s = bill.dateRange.start
        let e = bill.dateRange.end
        var city = f["city"].flatMap { $0 } ?? ""
        if city.isEmpty, let c0 = bill.cities.first { city = c0 }
        if city.isEmpty {
            let seller = f["seller_name"].flatMap { $0 } ?? f["hotel_name"].flatMap { $0 } ?? ""
            city = Self.extractHotelCity(from: seller) ?? String(seller.prefix(4))
        }
        if city.isEmpty { city = "未知" }

        let dateSeg: String
        if !s.isEmpty && !e.isEmpty && s != e {
            dateSeg = "\(Self.mmdd(s))-\(Self.mmdd(e))"
        } else {
            dateSeg = !s.isEmpty ? Self.mmdd(s) : dateMmdd
        }
        if dateSeg.isEmpty {
            return "\(city)住宿发票.pdf"
        }
        return "\(dateSeg) \(city)住宿发票.pdf"
    }
}

// MARK: - Session 创建工具

enum Sessions {
    static func createNew() -> String {
        UUID().uuidString.lowercased()
    }
}

// MARK: - 常驻地判断（用于 hotel folio/invoice city 修正）

extension SessionManager {
    /// 判断给定城市是否在 EXCLUDE_CITIES（常驻地）列表中
    /// 用于修 hotel_folio 的"客人地址被误识别为酒店城市" bug
    fileprivate static func isHomeCity(_ city: String) -> Bool {
        let raw = ProcessInfo.processInfo.environment["EXCLUDE_CITIES"] ?? ""
        let set = Set(raw
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty })
        return set.contains(city.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// MMDD → "MM-DD"
    private static func mmddToDateString(_ mmdd: String) -> String {
        guard mmdd.count == 4 else { return "" }
        return "2026-\(mmdd.prefix(2))-\(mmdd.suffix(2))"  // 默认 2026（同 absDateDiff 假设）
    }

    /// MMDD 向前推 N 天（用于 hotel check_in 推断）
    private static func shiftMMDDBackward(_ mmdd: String, days: Int) -> String? {
        guard mmdd.count == 4,
              let m = Int(mmdd.prefix(2)), let d = Int(mmdd.suffix(2)) else { return nil }
        var date = Calendar.current.date(from: DateComponents(year: 2026, month: m, day: d)) ?? Date()
        date = Calendar.current.date(byAdding: .day, value: -days, to: date) ?? date
        let comps = Calendar.current.dateComponents([.month, .day], from: date)
        guard let mo = comps.month, let dy = comps.day else { return nil }
        return String(format: "%02d%02d", mo, dy)
    }

    /// 两个 YYYY-MM-DD 之间的天数差
    private static func diffDays(from a: String, to b: String) -> Int {
        guard a.count >= 10, b.count >= 10 else { return -1 }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone(identifier: "UTC")
        guard let d1 = df.date(from: String(a.prefix(10))),
              let d2 = df.date(from: String(b.prefix(10))) else { return -1 }
        return Calendar.current.dateComponents([.day], from: d1, to: d2).day ?? -1
    }
}
