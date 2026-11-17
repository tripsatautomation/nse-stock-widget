import SwiftUI
import AppKit

// MARK: - Palette

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255)
    }
    static let bg = Color(hex: 0x0E1116)
    static let panel = Color(hex: 0x171C24)
    static let panel2 = Color(hex: 0x1E242E)
    static let hairline = Color(hex: 0x2A313D)
    static let fg = Color(hex: 0xE8ECF2)
    static let muted = Color(hex: 0x8A94A6)
    static let up = Color(hex: 0x30D158)
    static let down = Color(hex: 0xFF453A)
    static let flat = Color(hex: 0x98A2B3)
    static let accent = Color(hex: 0xFF9F0A)
    static let linkish = Color(hex: 0x9FC3FF)
}

func tone(_ v: Double?) -> Color {
    guard let v = v else { return .flat }
    if abs(v) < 0.0001 { return .flat }
    return v > 0 ? .up : .down
}

enum SortKey: String, CaseIterable {
    case pct = "Day %"
    case pnl = "P&L"
    case val = "Value"
    case sym = "A–Z"
}

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    @Published var quotes: [String: Quote] = [:]
    @Published var news: [String: [NewsItem]] = [:]
    @Published var newsLoading: Set<String> = []
    @Published var loading = false
    @Published var statusNote = ""
    @Published var sort: SortKey = .pct
    @Published var selected: String?
    @Published var now = Date()
    @Published var pinned = UserDefaults.standard.bool(forKey: "keepOnTop")

    /// Normal window by default — it should sit in the window order like any
    /// other app. Pinning is opt-in and remembered.
    func applyPin(_ on: Bool) {
        pinned = on
        UserDefaults.standard.set(on, forKey: "keepOnTop")
        for w in NSApp.windows where w.title == "Market" {
            w.level = on ? .floating : .normal
        }
        (NSApp.delegate as? AppDelegate)?.pinMenuItem?.state = on ? .on : .off
    }

    let config = ConfigLoader.load()
    private var lastFetch = Date.distantPast

    var marketState: MarketState { MarketClock.status(now).0 }
    var marketLabel: String { MarketClock.status(now).1 }
    var nifty: Double? { quotes["^NSEI"]?.pct }

    func tick() {
        now = Date()
        let gap: TimeInterval = (marketState == .closed) ? 300 : 60
        if !loading && Date().timeIntervalSince(lastFetch) > gap { refresh() }
    }

    func refresh() {
        guard !loading else { return }
        loading = true
        lastFetch = Date()
        let syms = config.holdings.map { $0.yahoo } + config.indices.map { $0.yahoo }
        Task { [weak self] in
            var got: [String: Quote] = [:]
            // small concurrency window — Yahoo throttles bursts
            for chunk in stride(from: 0, to: syms.count, by: 6).map({
                Array(syms[$0..<min($0 + 6, syms.count)]) }) {
                await withTaskGroup(of: (String, Quote?).self) { g in
                    for s in chunk { g.addTask { (s, try? await QuoteAPI.fetch(s)) } }
                    for await (s, q) in g { if let q = q { got[s] = q } }
                }
            }
            guard let self = self else { return }
            let missing = syms.filter { got[$0] == nil }
            for m in missing { if var old = self.quotes[m] { old.stale = true; got[m] = old } }
            self.quotes.merge(got) { _, new in new }
            self.news.removeAll()
            self.loading = false
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            self.statusNote = missing.isEmpty
                ? "updated \(f.string(from: Date()))"
                : "\(missing.count) not updated"
        }
    }

    // MARK: Signal read

    static let posWords = ["wins", "win", "bags", "order", "orders", "profit", "surge",
                           "surges", "jumps", "rally", "rallies", "upgrade", "upgrades",
                           "approval", "approved", "expansion", "record", "beats", "beat",
                           "growth", "dividend", "bonus", "buyback", "acquires",
                           "acquisition", "gains", "deal", "launch", "launches",
                           "partnership", "contract", "boost", "strong", "rises"]
    static let negWords = ["loss", "losses", "falls", "slumps", "plunges", "downgrade",
                           "downgrades", "probe", "ban", "recall", "fine", "penalty",
                           "decline", "declines", "cuts", "warning", "lawsuit", "resigns",
                           "resignation", "observations", "483", "fraud", "raid", "notice",
                           "slump", "drops", "weak", "miss", "misses", "delay", "halt"]

    /// Counts how many recent headlines read positive vs negative.
    func newsTone(_ symbol: String) -> (pos: Int, neg: Int, total: Int) {
        guard let items = news[symbol], !items.isEmpty else { return (0, 0, 0) }
        var p = 0, n = 0
        for it in items {
            let low = it.title.lowercased()
            let pc = Store.posWords.filter { low.contains($0) }.count
            let nc = Store.negWords.filter { low.contains($0) }.count
            if pc > nc { p += 1 } else if nc > pc { n += 1 }
        }
        return (p, n, items.count)
    }

    /// What the historical record says about where this stock currently sits.
    /// Descriptive only — deliberately no buy/sell/hold view and no price target.
    func signals(_ h: Holding) -> [(String, Color)] {
        guard let q = quotes[h.yahoo] else { return [] }
        var out: [(String, Color)] = []
        let p = q.price

        // Trend structure against its own moving averages
        if let s20 = q.sma20, let s50 = q.sma50 {
            let a20 = p >= s20, a50 = p >= s50
            var txt: String
            var c: Color
            switch (a20, a50) {
            case (true, true):
                txt = "Above both its 20- and 50-day averages — trending up on its own record."
                c = .up
            case (false, false):
                txt = "Below both its 20- and 50-day averages — trending down on its own record."
                c = .down
            case (true, false):
                txt = "Above the 20-day but below the 50-day — a short-term bounce inside a weaker trend."
                c = .accent
            case (false, true):
                txt = "Below the 20-day but still above the 50-day — cooling off from a stronger trend."
                c = .accent
            }
            if let s200 = q.sma200 {
                txt += p >= s200 ? " Still above its 200-day line."
                                 : " Below its 200-day line, so the year-long trend is down."
            }
            out.append((txt, c))
        }

        // Momentum
        if let r = q.rsi14 {
            let label: String, c: Color
            if r >= 70 { label = "overbought territory — it has run hard and often cools from here"; c = .accent }
            else if r <= 30 { label = "oversold territory — it has been sold hard and often steadies from here"; c = .accent }
            else if r >= 55 { label = "firm but not stretched"; c = .up }
            else if r <= 45 { label = "soft but not washed out"; c = .down }
            else { label = "neutral"; c = .muted }
            out.append((String(format: "RSI %.0f — %@.", r, label), c))
        }

        // Is today's move big for this stock?
        if let sd = q.sigma1d, sd > 0 {
            let mult = abs(q.pct) / sd
            let desc = mult >= 2 ? "a genuinely big day for this stock"
                     : (mult >= 1 ? "a larger-than-usual day" : "within its normal daily noise")
            out.append((String(format: "Today's %@ move is %.1f× its typical daily swing (±%.1f%%) — %@.",
                               Fmt.pct(q.pct), mult, sd, desc),
                        mult >= 2 ? .accent : .muted))
        }
        if let av = q.annVol {
            out.append((String(format: "Annualised volatility %.0f%%.", av), .muted))
        }

        // Longer-horizon record vs the index
        if let c3 = q.chg3mo, !(h.etf == true) {
            out.append(("3-month record: \(Fmt.pct(c3)).", tone(c3)))
        }
        return out
    }

    /// Pure arithmetic between the current price and levels from the record.
    func levels(_ h: Holding) -> [(String, Color)] {
        guard let q = quotes[h.yahoo], q.price > 0 else { return [] }
        let p = q.price
        var out: [(String, Color)] = []
        func line(_ label: String, _ target: Double?) {
            guard let t = target, t > 0 else { return }
            let d = (t / p - 1) * 100
            out.append((String(format: "%@ %@  (%@ from here)", label, Fmt.inr(t, 2), Fmt.pct(d)),
                        tone(d)))
        }
        line("Back to its 50-day average", q.sma50)
        line("Back to its 52-week high", q.high52)
        line("Down to its 52-week low", q.low52)
        if let sd = q.sigma1d {
            out.append((String(format: "A normal day for it is ±%.1f%%; a big one ±%.1f%%.",
                               sd, sd * 2), .muted))
        }
        return out
    }

    func loadNews(for h: Holding) {
        guard news[h.symbol] == nil, !newsLoading.contains(h.symbol) else { return }
        newsLoading.insert(h.symbol)
        Task { [weak self] in
            var items = await NewsAPI.fetch(name: h.name, days: 7)
            if items.isEmpty { items = await NewsAPI.fetch(name: h.name, days: 21) }
            guard let self = self else { return }
            self.news[h.symbol] = items
            self.newsLoading.remove(h.symbol)
        }
    }

    // Portfolio maths
    struct Line {
        let h: Holding, q: Quote?
        var value: Double { (q?.price ?? 0) * h.qty }
        var day: Double { (q?.change ?? 0) * h.qty }
        var pnl: Double? { guard let p = q?.price, let a = h.avg else { return nil }
                           return (p - a) * h.qty }
        var pnlPct: Double? { guard let a = h.avg, let p = q?.price, a > 0 else { return nil }
                              return (p - a) / a * 100 }
    }

    var lines: [Line] { config.holdings.map { Line(h: $0, q: quotes[$0.yahoo]) } }

    var sorted: [Line] {
        lines.sorted { a, b in
            switch sort {
            case .pct: return (a.q?.pct ?? -999) > (b.q?.pct ?? -999)
            case .pnl: return (a.pnl ?? -1e18) > (b.pnl ?? -1e18)
            case .val: return a.value > b.value
            case .sym: return a.h.symbol < b.h.symbol
            }
        }
    }

    var totalValue: Double { lines.reduce(0) { $0 + $1.value } }
    var totalDay: Double { lines.reduce(0) { $0 + $1.day } }
    var invested: Double {
        lines.reduce(0) { acc, l in acc + (l.h.avg.map { $0 * l.h.qty } ?? 0) }
    }
    var totalPnl: Double { lines.reduce(0) { $0 + ($1.pnl ?? 0) } }

    /// Plain-language read of what the numbers say about a move.
    func explain(_ h: Holding) -> [(String, Color)] {
        guard let q = quotes[h.yahoo] else {
            return [("No price data yet — hit refresh.", .muted)]
        }
        var out: [(String, Color)] = []
        out.append(("₹\(Fmt.inr(q.price, 2))   \(Fmt.signed(q.change, 2)) (\(Fmt.pct(q.pct))) today",
                    tone(q.pct)))
        if h.etf == true {
            out.append(("ETF — it tracks the \(h.name) index, so it moves with the index rather than on company news.", .muted))
        } else if let n = nifty {
            let d = q.pct - n
            out.append(((d > 0 ? "Outperforming" : "Underperforming")
                        + String(format: " NIFTY by %.2f%% today (NIFTY %@).", abs(d), Fmt.pct(n)),
                        tone(d)))
        }
        if let vr = q.volRatio {
            if vr >= 2 {
                out.append((String(format: "Volume is %.1f× its 20-day average — a real event, not drift.", vr), .accent))
            } else if vr < 0.6 {
                out.append((String(format: "Volume only %.1f× average — a quiet, low-conviction move.", vr), .muted))
            } else {
                out.append((String(format: "Volume %.1f× its 20-day average.", vr), .muted))
            }
        }
        var bits: [String] = []
        if let c5 = q.chg5d { bits.append("5-day \(Fmt.pct(c5))") }
        if let c1 = q.chg1mo { bits.append("1-month \(Fmt.pct(c1))") }
        if !bits.isEmpty { out.append(("Trend: " + bits.joined(separator: "  ·  "), tone(q.chg5d))) }
        if let hi = q.high52, let lo = q.low52, hi > lo {
            let pos = (q.price - lo) / (hi - lo) * 100
            out.append((String(format: "%.0f%% up its 52-week range (%@ – %@).", pos,
                               Fmt.inr(lo, 0), Fmt.inr(hi, 0)), .muted))
        }
        if let dl = q.dayLow, let dh = q.dayHigh {
            out.append(("Day range \(Fmt.inr(dl, 2)) – \(Fmt.inr(dh, 2)).", .muted))
        }
        if q.stale { out.append(("Showing last cached price — the latest fetch failed.", .accent)) }
        return out
    }
}

// MARK: - Views

struct HeaderBar: View {
    @ObservedObject var store: Store
    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(store.marketState == .open ? Color.up
                      : (store.marketState == .preopen ? Color.accent : Color.muted))
                .frame(width: 7, height: 7)
            Text(store.marketLabel)
                .font(.system(size: 11, weight: .semibold)).foregroundColor(.fg)
            Text(MarketClock.clockString(store.now))
                .font(.system(size: 10, design: .monospaced)).foregroundColor(.muted)
            Spacer()
            Button { store.refresh() } label: {
                Image(systemName: store.loading ? "arrow.triangle.2.circlepath"
                                                : "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundColor(store.loading ? .accent : .muted)
            }.buttonStyle(.plain).help("Refresh now")
            Button {
                store.applyPin(!store.pinned)
            } label: {
                Image(systemName: store.pinned ? "pin.fill" : "pin.slash")
                    .font(.system(size: 11))
                    .foregroundColor(store.pinned ? .accent : .muted)
            }.buttonStyle(.plain)
             .help(store.pinned ? "Keeping on top — click to unpin (⌘T)"
                                : "Keep on top of other windows (⌘T)")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.panel)
    }
}

struct IndexStrip: View {
    @ObservedObject var store: Store
    var body: some View {
        let cols = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]
        LazyVGrid(columns: cols, spacing: 6) {
            ForEach(store.config.indices) { ix in
                let q = store.quotes[ix.yahoo]
                VStack(alignment: .leading, spacing: 1) {
                    Text(ix.symbol).font(.system(size: 9, weight: .medium)).foregroundColor(.muted)
                    Text(Fmt.inr(q?.price, 2))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(.fg)
                    Text("\(Fmt.signed(q?.change, 2))  \(Fmt.pct(q?.pct))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(tone(q?.pct))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(Color.panel).cornerRadius(7)
            }
        }
    }
}

struct SummaryCard: View {
    @ObservedObject var store: Store
    var body: some View {
        let tv = store.totalValue, td = store.totalDay
        let dpct = (tv - td) != 0 ? td / (tv - td) * 100 : 0
        let upct = store.invested > 0 ? store.totalPnl / store.invested * 100 : 0
        VStack(spacing: 5) {
            HStack {
                Text("MARKET VALUE").font(.system(size: 9, weight: .medium)).foregroundColor(.muted)
                Spacer()
                Text("₹ " + Fmt.inr(tv))
                    .font(.system(size: 17, weight: .bold, design: .monospaced)).foregroundColor(.fg)
            }
            HStack {
                Text("DAY'S P&L").font(.system(size: 9, weight: .medium)).foregroundColor(.muted)
                Spacer()
                Text("\(Fmt.signed(td))  (\(Fmt.pct(dpct)))")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(tone(td))
            }
            HStack {
                Text("UNREALISED P&L").font(.system(size: 9, weight: .medium)).foregroundColor(.muted)
                Spacer()
                Text("\(Fmt.signed(store.totalPnl))  (\(Fmt.pct(upct)))")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(tone(store.totalPnl))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color.panel).cornerRadius(9)
    }
}

struct DetailPanel: View {
    @ObservedObject var store: Store
    let h: Holding

    func toneLine(_ t: (pos: Int, neg: Int, total: Int)) -> String {
        if t.pos == 0 && t.neg == 0 {
            return "Tone: \(t.total) headline(s), none clearly positive or negative."
        }
        let lead = t.pos > t.neg ? "leans positive" : (t.neg > t.pos ? "leans negative" : "is mixed")
        return "Tone: of \(t.total) recent headlines, \(t.pos) read positive and "
             + "\(t.neg) negative — coverage \(lead)."
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(store.explain(h).enumerated()), id: \.offset) { _, row in
                Text(row.0).font(.system(size: 10)).foregroundColor(row.1)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().background(Color.hairline).padding(.vertical, 3)
            Text("WHAT'S IN THE NEWS")
                .font(.system(size: 9, weight: .bold)).foregroundColor(.muted)
            if store.newsLoading.contains(h.symbol) {
                Text("loading…").font(.system(size: 10)).foregroundColor(.muted)
            } else if let items = store.news[h.symbol] {
                if items.isEmpty {
                    Text("No company news in the last 3 weeks — likely moving with its sector or the index.")
                        .font(.system(size: 10)).foregroundColor(.muted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(items) { it in
                        VStack(alignment: .leading, spacing: 1) {
                            Text("• " + it.title)
                                .font(.system(size: 10)).foregroundColor(.linkish)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("   \(it.source) · \(Fmt.ago(it.date))")
                                .font(.system(size: 9)).foregroundColor(.muted)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if let u = URL(string: it.link) { NSWorkspace.shared.open(u) }
                        }
                    }
                    let t = store.newsTone(h.symbol)
                    if t.total > 0 {
                        Text(toneLine(t))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(t.pos > t.neg ? .up : (t.neg > t.pos ? .down : .muted))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                }
            }

            let sig = store.signals(h)
            if !sig.isEmpty {
                Divider().background(Color.hairline).padding(.vertical, 3)
                Text("WHAT THE RECORD SAYS")
                    .font(.system(size: 9, weight: .bold)).foregroundColor(.muted)
                ForEach(Array(sig.enumerated()), id: \.offset) { _, row in
                    Text(row.0).font(.system(size: 10)).foregroundColor(row.1)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            let lv = store.levels(h)
            if !lv.isEmpty {
                Divider().background(Color.hairline).padding(.vertical, 3)
                Text("DISTANCE TO KEY LEVELS")
                    .font(.system(size: 9, weight: .bold)).foregroundColor(.muted)
                ForEach(Array(lv.enumerated()), id: \.offset) { _, row in
                    Text(row.0).font(.system(size: 10, design: .monospaced))
                        .foregroundColor(row.1)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("Signals and arithmetic from past data — not advice, not a forecast, "
                     + "and not a buy or sell view. Past moves don't determine future ones.")
                    .font(.system(size: 9, weight: .medium)).foregroundColor(.accent)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.panel2)
        .onAppear { store.loadNews(for: h) }
    }
}

struct HoldingRow: View {
    @ObservedObject var store: Store
    let line: Store.Line
    var body: some View {
        let h = line.h, q = line.q
        let hot = (q?.volRatio ?? 0) >= 2
        let isSel = store.selected == h.symbol
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 3) {
                        Text(h.symbol).font(.system(size: 11, weight: .semibold))
                            .foregroundColor(hot ? .accent : .fg)
                        if hot {
                            Image(systemName: "bolt.fill").font(.system(size: 7))
                                .foregroundColor(.accent)
                        }
                    }
                    Text("\(Int(h.qty)) @ \(h.avg.map { Fmt.inr($0, 2) } ?? "—")"
                         + ((q?.stale ?? false) ? " · stale" : ""))
                        .font(.system(size: 9, design: .monospaced)).foregroundColor(.muted)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(Fmt.inr(line.pnl))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(line.pnl == nil ? .muted : tone(line.pnl))
                    Text(Fmt.inr(line.value))
                        .font(.system(size: 9, design: .monospaced)).foregroundColor(.muted)
                }
                VStack(alignment: .trailing, spacing: 1) {
                    Text(Fmt.inr(q?.price, 2))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(.fg)
                    Text(Fmt.pct(q?.pct))
                        .font(.system(size: 10, design: .monospaced)).foregroundColor(tone(q?.pct))
                }.frame(width: 74, alignment: .trailing)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(isSel ? Color.panel2 : Color.panel)
            .contentShape(Rectangle())
            .onTapGesture {
                store.selected = isSel ? nil : h.symbol
                if !isSel { store.loadNews(for: h) }
            }
            if isSel { DetailPanel(store: store, h: h) }
        }
        .cornerRadius(7)
    }
}

struct ContentView: View {
    @ObservedObject var store: Store
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(store: store)
            ScrollView {
                VStack(spacing: 8) {
                    IndexStrip(store: store)
                    SummaryCard(store: store)
                    HStack(spacing: 10) {
                        Text("SORT").font(.system(size: 8, weight: .bold)).foregroundColor(.muted)
                        ForEach(SortKey.allCases, id: \.self) { k in
                            Text(k.rawValue)
                                .font(.system(size: 10, weight: store.sort == k ? .semibold : .regular))
                                .foregroundColor(store.sort == k ? .accent : .muted)
                                .onTapGesture { store.sort = k }
                        }
                        Spacer()
                        Text(store.statusNote).font(.system(size: 8)).foregroundColor(.muted)
                    }
                    VStack(spacing: 3) {
                        ForEach(store.sorted, id: \.h.symbol) { line in
                            HoldingRow(store: store, line: line)
                        }
                    }
                    if store.config.holdings.isEmpty {
                        Text("holdings.json not found next to the app.")
                            .font(.system(size: 11)).foregroundColor(.accent).padding()
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 10)
            }
        }
        .background(Color.bg)
        .onReceive(timer) { _ in store.tick() }
    }
}

// MARK: - App shell

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var pinMenuItem: NSMenuItem?
    let store = Store()

    func applicationDidFinishLaunching(_ n: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Market"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(red: 0.055, green: 0.067, blue: 0.086, alpha: 1)
        window.level = store.pinned ? .floating : .normal
        window.minSize = NSSize(width: 380, height: 420)
        window.contentView = NSHostingView(rootView: ContentView(store: store))
        window.setFrameAutosaveName("MarketWidget")
        if window.frame.origin == .zero {
            window.center()
            var f = window.frame
            if let s = NSScreen.main {
                f.origin = CGPoint(x: s.visibleFrame.maxX - f.width - 24,
                                   y: s.visibleFrame.maxY - f.height - 24)
            }
            window.setFrame(f, display: true)
        }
        // A fresh launch should show the window (at login macOS may otherwise
        // restore it minimized). After that it behaves like any normal window:
        // ⌘M minimises, ⌘H hides, and it goes behind whatever you focus next.
        window.isRestorable = false
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        buildMenu()
        store.refresh()
    }

    @objc func togglePin() { store.applyPin(!store.pinned) }

    /// Without a main menu an NSApplication gets no standard shortcuts at all —
    /// no ⌘H to hide, no ⌘M to minimise, no ⌘Q to quit.
    func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Stock Widget",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        let pin = NSMenuItem(title: "Keep on Top", action: #selector(togglePin),
                             keyEquivalent: "t")
        pin.target = self
        pin.state = store.pinned ? .on : .off
        appMenu.addItem(pin)
        pinMenuItem = pin
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Stock Widget",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "Hide Others",
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Stock Widget",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let winItem = NSMenuItem()
        let winMenu = NSMenu(title: "Window")
        winMenu.addItem(withTitle: "Minimize",
                        action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winMenu.addItem(withTitle: "Zoom",
                        action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        winMenu.addItem(.separator())
        winMenu.addItem(withTitle: "Close",
                        action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winItem.submenu = winMenu
        main.addItem(winItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = winMenu
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ a: NSApplication) -> Bool { true }
}

// NSApplication.delegate is weak — keep a strong reference alive here.
var gDelegate: AppDelegate?


MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let d = AppDelegate()
    gDelegate = d
    app.delegate = d
    app.run()
}
