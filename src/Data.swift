import Foundation

// MARK: - Config

struct Holding: Codable, Identifiable {
    let symbol: String
    let yahoo: String
    let name: String
    let qty: Double
    let avg: Double?
    let etf: Bool?
    var id: String { symbol }
}

struct IndexDef: Codable, Identifiable {
    let symbol: String
    let yahoo: String
    var id: String { yahoo }
}

struct Config: Codable {
    let holdings: [Holding]
    let indices: [IndexDef]
}

enum ConfigLoader {
    /// holdings.json sits next to the .app so it stays editable after build.
    static func locate() -> URL? {
        let fm = FileManager.default
        let exe = Bundle.main.bundleURL.deletingLastPathComponent()
        let roots = [exe, exe.deletingLastPathComponent()]
        // Your own holdings.json wins; the committed sample is the fallback so a
        // fresh clone runs before you have configured anything.
        for name in ["holdings.json", "holdings.example.json"] {
            for root in roots {
                let u = root.appendingPathComponent(name)
                if fm.fileExists(atPath: u.path) { return u }
            }
            if let r = Bundle.main.url(forResource: (name as NSString).deletingPathExtension,
                                       withExtension: "json") { return r }
        }
        return nil
    }

    static func load() -> Config {
        guard let url = locate(), let d = try? Data(contentsOf: url),
              let c = try? JSONDecoder().decode(Config.self, from: d) else {
            return Config(holdings: [], indices: [])
        }
        return c
    }
}

// MARK: - Market clock (NSE equity hours: 09:15–15:30 IST, Mon–Fri)

enum MarketState { case open, preopen, closed }

enum MarketClock {
    static var ist: TimeZone { TimeZone(secondsFromGMT: 19800)! }

    static func cal() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = ist
        return c
    }

    static func status(_ now: Date = Date()) -> (MarketState, String) {
        let c = cal()
        let p = c.dateComponents([.hour, .minute, .weekday], from: now)
        let wd = p.weekday ?? 1               // 1 = Sunday
        if wd == 1 || wd == 7 { return (.closed, "CLOSED · Weekend") }
        let m = (p.hour ?? 0) * 60 + (p.minute ?? 0)
        if m < 540 { return (.closed, "PRE-OPEN AT 09:00") }
        if m < 555 { return (.preopen, "PRE-OPEN") }
        if m <= 930 { return (.open, "MARKET OPEN") }
        return (.closed, "CLOSED FOR THE DAY")
    }

    static func clockString(_ now: Date = Date()) -> String {
        let f = DateFormatter()
        f.timeZone = ist
        f.dateFormat = "HH:mm:ss"
        return f.string(from: now) + " IST"
    }
}

// MARK: - Quotes

struct Quote {
    var symbol: String
    var name: String
    var price: Double
    var prev: Double
    var pct: Double
    var change: Double { price - prev }
    var dayHigh: Double?
    var dayLow: Double?
    var high52: Double?
    var low52: Double?
    var volume: Double?
    var avgVolume: Double?
    var chg5d: Double?
    var chg1mo: Double?
    var stale: Bool = false
    var volRatio: Double? {
        guard let v = volume, let a = avgVolume, a > 0 else { return nil }
        return v / a
    }
}

enum Net {
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0",
                                   "Accept-Language": "en-IN,en;q=0.9"]
        return URLSession(configuration: c)
    }()

    static func get(_ url: URL, tries: Int = 3) async throws -> Data {
        var last: Error = URLError(.unknown)
        for i in 0..<tries {
            do {
                let (d, r) = try await session.data(from: url)
                if let h = r as? HTTPURLResponse, h.statusCode >= 400 {
                    throw URLError(.badServerResponse)       // 429 etc.
                }
                return d
            } catch {
                last = error
                try? await Task.sleep(nanoseconds: UInt64(0.7 * Double(i + 1) * 1e9))
            }
        }
        throw last
    }
}

enum QuoteAPI {
    /// One chart call gives the live price plus a month of daily bars.
    static func fetch(_ ysym: String) async throws -> Quote {
        let enc = ysym.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-^"))) ?? ysym
        let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/"
                      + enc + "?range=1mo&interval=1d")!
        let data = try await Net.get(url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let chart = root["chart"] as? [String: Any],
              let results = chart["result"] as? [[String: Any]],
              let res = results.first,
              let meta = res["meta"] as? [String: Any],
              let price = meta["regularMarketPrice"] as? Double
        else { throw URLError(.cannotParseResponse) }

        var closes: [Double] = []
        var vols: [Double] = []
        if let ind = res["indicators"] as? [String: Any],
           let qs = ind["quote"] as? [[String: Any]], let q = qs.first {
            closes = (q["close"] as? [Any] ?? []).compactMap { $0 as? Double }
            vols = (q["volume"] as? [Any] ?? []).compactMap { $0 as? Double }
        }

        // NOTE: with range=1mo, chartPreviousClose is LAST MONTH's close, not yesterday's.
        var pct = meta["regularMarketChangePercent"] as? Double
        var prev: Double
        if let p = pct, p != 0 || closes.count < 2 {
            prev = price / (1 + p / 100)
        } else if closes.count >= 2 {
            prev = closes[closes.count - 2]
            pct = (price - prev) / prev * 100
        } else {
            prev = price
            pct = 0
        }
        if prev <= 0 { prev = price }

        func chgOver(_ n: Int) -> Double? {
            guard closes.count > n else { return nil }
            let base = closes[closes.count - 1 - n]
            guard base > 0 else { return nil }
            return (price - base) / base * 100
        }

        let recent = vols.count > 2 ? Array(vols.suffix(21).dropLast()) : []
        let avgVol = recent.isEmpty ? nil : recent.reduce(0, +) / Double(recent.count)

        return Quote(
            symbol: ysym,
            name: (meta["longName"] as? String) ?? (meta["shortName"] as? String) ?? ysym,
            price: price, prev: prev, pct: pct ?? 0,
            dayHigh: meta["regularMarketDayHigh"] as? Double,
            dayLow: meta["regularMarketDayLow"] as? Double,
            high52: meta["fiftyTwoWeekHigh"] as? Double,
            low52: meta["fiftyTwoWeekLow"] as? Double,
            volume: meta["regularMarketVolume"] as? Double,
            avgVolume: avgVol,
            chg5d: chgOver(5),
            chg1mo: closes.count > 1 ? chgOver(closes.count - 1) : nil)
    }
}

// MARK: - News

struct NewsItem: Identifiable {
    let id = UUID()
    let title: String
    let source: String
    let link: String
    let date: Date?
    let score: Int
}

private final class RSSParser: NSObject, XMLParserDelegate {
    var items: [(String, String, String, String)] = []
    private var cur: String?
    private var title = "", link = "", source = "", pub = ""

    func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?,
                qualifiedName q: String?, attributes a: [String: String] = [:]) {
        cur = e
        if e == "item" { title = ""; link = ""; source = ""; pub = "" }
    }
    func parser(_ p: XMLParser, foundCharacters s: String) {
        switch cur {
        case "title": title += s
        case "link": link += s
        case "source": source += s
        case "pubDate": pub += s
        default: break
        }
    }
    func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?,
                qualifiedName q: String?) {
        if e == "item" {
            items.append((title.trimmingCharacters(in: .whitespacesAndNewlines),
                          source.trimmingCharacters(in: .whitespacesAndNewlines),
                          link.trimmingCharacters(in: .whitespacesAndNewlines),
                          pub.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        cur = nil
    }
}

enum NewsAPI {
    // SEO price-page spam that crowds out real news
    static let junkSrc = ["univest", "upstox", "scanx", "munafa", "5paisa", "stockinvest",
                          "walletinvestor", "topstockresearch", "equitypandit", "investing.com",
                          "tickertape", "marketsmojo", "trendlyne", "simply wall st", "yahoo"]
    static let junkPat = ["share price prediction", "price prediction", "share price today",
                          "stock price &", "price & chart", "live nse", "share price target",
                          "seasonal returns", "stock forecast", "technical analysis of",
                          "should you buy", "share price live", "stock price today", "nse/bse"]
    // words that signal an actual market-moving event
    static let eventWords = ["order", "wins", "contract", "bags", "profit", "loss", "results",
                             "q1", "q2", "q3", "q4", "earnings", "revenue", "margin",
                             "acquisition", "acquires", "stake", "merger", "deal", "upgrade",
                             "downgrade", "brokerage", "rating", "target price", "dividend",
                             "bonus", "buyback", "block deal", "launch", "approval", "usfda",
                             "fda", "capex", "expansion", "guidance", "demerger", "ipo",
                             "tariff", "gst", "rbi", "probe", "ban", "recall", "jumps",
                             "surges", "slumps", "plunges", "rallies", "falls"]
    static let stop: Set<String> = ["ltd", "limited", "company", "india", "industries",
                                    "corporation", "corp", "services", "the", "and", "co"]

    static func keywords(_ name: String) -> [String] {
        name.lowercased().components(separatedBy: CharacterSet.letters.inverted)
            .filter { $0.count >= 3 && !stop.contains($0) }
    }

    static func fetch(name: String, days: Int = 7, limit: Int = 5) async -> [NewsItem] {
        let query = "\"\(name)\" when:\(days)d"
        guard let enc = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string: "https://news.google.com/rss/search?q=\(enc)&hl=en-IN&gl=IN&ceid=IN:en"),
              let data = try? await Net.get(url, tries: 2) else { return [] }

        let p = XMLParser(data: data)
        let d = RSSParser()
        p.delegate = d
        guard p.parse() else { return [] }

        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"

        let kws = keywords(name)
        var out: [NewsItem] = []
        for (rawTitle, src, link, pub) in d.items {
            var title = rawTitle
            if !src.isEmpty, title.hasSuffix(" - " + src) {
                title = String(title.dropLast(src.count + 3))
            }
            let low = title.lowercased(), slow = src.lowercased()
            if junkSrc.contains(where: { slow.contains($0) }) { continue }
            if junkPat.contains(where: { low.contains($0) }) { continue }
            let hits = kws.filter { low.contains($0) }.count
            if hits == 0 { continue }          // must actually name the company
            var score = 2 * hits
            if let first = kws.first, low.hasPrefix(first) { score += 3 }
            score += eventWords.filter { low.contains($0) }.count
            let date = fmt.date(from: pub)
            if let dt = date, Date().timeIntervalSince(dt) < 86400 * 1.5 { score += 2 }
            out.append(NewsItem(title: title, source: src, link: link, date: date, score: score))
        }
        out.sort { a, b in
            a.score != b.score ? a.score > b.score
                : (a.date ?? .distantPast) > (b.date ?? .distantPast)
        }
        return Array(out.prefix(limit))
    }
}

// MARK: - Formatting

enum Fmt {
    /// Indian digit grouping: 8,73,403
    static func inr(_ n: Double?, _ dec: Int = 0) -> String {
        guard let n = n else { return "--" }
        let neg = n < 0
        let a = abs(n)
        let whole = Int(a)
        var s = String(whole)
        if s.count > 3 {
            var head = String(s.dropLast(3))
            let tail = String(s.suffix(3))
            var parts: [String] = []
            while head.count > 2 {
                parts.insert(String(head.suffix(2)), at: 0)
                head = String(head.dropLast(2))
            }
            if !head.isEmpty { parts.insert(head, at: 0) }
            s = parts.joined(separator: ",") + "," + tail
        }
        if dec > 0 {
            let frac = a - Double(whole)
            let fs = String(format: "%.\(dec)f", frac)
            s += String(fs.dropFirst())
        }
        return (neg ? "−" : "") + s
    }

    static func signed(_ n: Double?, _ dec: Int = 0) -> String {
        guard let n = n else { return "--" }
        return (n >= 0 ? "+" : "−") + inr(abs(n), dec)
    }

    static func pct(_ p: Double?) -> String {
        guard let p = p else { return "--" }
        return String(format: "%+.2f%%", p)
    }

    static func ago(_ d: Date?) -> String {
        guard let d = d else { return "" }
        let s = Date().timeIntervalSince(d)
        if s < 3600 { return "\(max(1, Int(s / 60)))m ago" }
        if s < 86400 { return "\(Int(s / 3600))h ago" }
        return "\(Int(s / 86400))d ago"
    }
}
