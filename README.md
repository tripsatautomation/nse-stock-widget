# Stock Widget

A floating desktop widget for an NSE portfolio: live prices, P&L, and a read on
*why* each stock is moving. Native macOS app — no dependencies, no API keys,
no accounts.

![platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey)
![deps](https://img.shields.io/badge/dependencies-none-brightgreen)

## What it does

- **Live NSE prices** for your holdings, with position P&L and day P&L
- **Index strip** — NIFTY 50, SENSEX, BANK NIFTY, INDIA VIX
- **A "why is it moving" panel** on every stock (see below)
- **Behaves like a normal window** — ⌘M minimises, ⌘H hides, it sits in the
  normal window order. Keep-on-top is opt-in (⌘T) and remembered
- Auto-refreshes every 60s while the market is open, every 5 min when closed
- Real NSE market hours (09:15–15:30 IST, Mon–Fri), shown as a live status

## The "why is it moving" panel

Click any stock and it expands into something like:

```
₹257.80   −4.40 (−1.68%) today
Underperforming NIFTY by 2.48% today (NIFTY +0.80%).
Volume only 0.5× average — a quiet, low-conviction move.
Trend: 5-day −0.06%  ·  1-month +2.98%
19% up its 52-week range (242 – 324).
Day range 257.40 – 261.75.

WHAT'S IN THE NEWS
• Power Grid Corporation approves investment of ₹220.09 crore
  Business Upturn · 12h ago
```

| Line | What it tells you |
|---|---|
| Out/underperforming NIFTY | Stock-specific move, or just the whole market? |
| Volume vs 20-day average | 2×+ = a real event. Under 0.6× = quiet drift. |
| 5-day / 1-month trend | Is today part of a run, or a reversal? |
| 52-week range position | Near its highs or near its lows. |
| What's in the news | Recent headlines that actually name the company. |

A symbol turns **orange with a bolt** when volume is 2×+ its 20-day average —
a quick scan for "something is actually happening here".

**On the news:** headlines are evidence, not a verdict. The widget shows what's
being reported so you can judge the cause yourself — it never claims a headline
*caused* a price move. SEO "share price prediction" pages are filtered out, and
a headline has to actually name the company to show up.

## Setup

```bash
git clone https://github.com/tripsatautomation/nse-stock-widget.git
cd nse-stock-widget
./build.sh
open "Stock Widget.app"
```

On first run it seeds your config from the bundled sample, so it works
immediately. Then edit your positions (see below) and restart.

## Window behaviour

| | |
|---|---|
| ⌘M | Minimise |
| ⌘H | Hide the app (⌥⌘H hides everything else) |
| ⌘T | Keep on Top — off by default, remembered between launches |
| ⌘W / ⌘Q | Close / Quit |

By default it is an ordinary window: click another app and it goes behind,
like anything else. Turn on **Keep on Top** (menu or the pin button) only if
you want it floating above your work.

## Configuring holdings

Your positions live at:

```
~/Library/Application Support/StockWidget/holdings.json
```

> **Why not next to the app?** macOS gates an app's access to Desktop,
> Documents and Downloads behind a consent prompt, and the file read *blocks
> until that prompt is answered*. An ad-hoc signed app also gets a new code
> identity on every rebuild, which revokes any grant it was given before. A
> config file in one of those folders can therefore hang the app at launch with
> no window and no error. Application Support needs no permission, so the
> config lives there and the sample ships inside the app bundle.

Open it with:

```bash
open -e ~/Library/Application\ Support/StockWidget/holdings.json
```

Each row looks like:

```json
{"symbol": "BHARTIARTL", "yahoo": "BHARTIARTL.NS", "name": "Bharti Airtel", "qty": 10, "avg": 1600.00}
```

- `symbol` — what's shown in the widget (use whatever your broker calls it)
- `yahoo` — the fetch symbol. NSE equities are `SYMBOL.NS`
- `name` — full company name; this is what the news search uses
- `qty` / `avg` — your position. Set `avg` to `null` to show the row without P&L
- `"etf": true` — marks index trackers, so the panel explains them as
  index-linked rather than looking for company news

Restart the app after editing. No rebuild needed — the JSON is read at runtime.
`holdings.example.json` in the repo is only the template; it is copied into the
app bundle at build time and used to seed your config on first run.

> **Tip:** NSE has renamed several ETF tickers, so what your broker displays may
> not be what Yahoo uses. If a row shows no price, look the symbol up at
> `https://query2.finance.yahoo.com/v1/finance/search?q=YOUR_TICKER`.

## Launching at login

Register it as a LaunchAgent (edit the path to match where you cloned it):

```bash
cp local.stockwidget.plist.example ~/Library/LaunchAgents/local.stockwidget.plist
# edit the path inside, then:
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.stockwidget.plist
```

It then also appears in **System Settings → General → Login Items** under
"Allow in the Background". To remove it:

```bash
launchctl bootout gui/$(id -u)/local.stockwidget
rm ~/Library/LaunchAgents/local.stockwidget.plist
```

## Building

```bash
./build.sh
```

Requires the Swift toolchain that ships with Xcode or the Command Line Tools.
No package manager, no third-party libraries — everything is Foundation,
AppKit and SwiftUI.

```
src/Data.swift   config, market clock, quote fetch, news fetch + ranking, formatting
src/main.swift   SwiftUI views, portfolio maths, the explain() logic, menus, app shell
```

## Data sources

| | |
|---|---|
| Prices | Yahoo Finance chart API — one call per symbol gives the live price plus a month of daily bars for trend and volume |
| News | Google News RSS, India edition |

Both are public endpoints needing no key. Prices can lag by up to a minute —
treat the numbers as indicative, and your broker as the source of truth for P&L.

## Licence

MIT
