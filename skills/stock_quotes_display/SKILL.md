---
{
  "name": "stock_quotes_display",
  "description": "Show real-time stock quotes and detailed market fields on the board LCD using Eastmoney HTTP quotes API.",
  "author": "ESP-Claw contributor",
  "metadata": {
    "category": ["utility", "ui"],
    "tags": ["stock", "quotes", "eastmoney", "market"],
    "peripherals": ["display"],
    "cap_groups": ["cap_lua", "cap_http_request"],
    "manage_mode": "web"
  },
  "simulator": {
    "entry": "scripts/stock_quotes_display.lua",
    "files": [
      "scripts/stock_quotes_display.lua"
    ]
  }
}
---

# Stock Quotes Display

Use this skill when the user asks to show stock quotes, stock prices, market
indexes, real-time stock information, or Eastmoney quote data on the device
screen.

The bundled Lua script fetches Eastmoney's `push2.eastmoney.com` quote endpoint,
parses the returned JSON, and renders a compact quote dashboard on the LCD. The
screen uses ASCII labels because the current display text module only supports
ASCII text.

## Requirements

- A display device declared as `display_lcd` in board hardware info.
- The HTTP request capability enabled.
- The HTTP allowlist must include `eastmoney.com`, `push2.eastmoney.com`, or
  `*`. If the script reports an allowlist error, add the domain in the Web
  Console HTTP allowlist setting.
- Network access from the device.

## Tool Call Inputs

```json
{
  "path": "{CUR_SKILL_DIR}/scripts/stock_quotes_display.lua",
  "args": {},
  "timeout_ms": 0
}
```

Pass an empty `args` object to show default China market indexes:

- `1.000001`: Shanghai Composite Index
- `0.399001`: Shenzhen Component Index
- `0.399006`: ChiNext Index

Common optional args:

| Arg | Default | Meaning |
|-----|---------|---------|
| `secids` | `"1.000001,0.399001,0.399006"` | Eastmoney secid list. Use comma-separated values such as `1.600519,0.000001`. |
| `refresh_ms` | `15000` | Quote refresh interval in milliseconds. |
| `run_time_ms` | `0` | Runtime in milliseconds. `0` means keep running until stopped. |
| `rotate` | `true` | Rotate the detailed quote card through all returned securities. |
| `detail_index` | `1` | 1-based detail card index when `rotate` is false. |

## Eastmoney Fields

The script requests detailed fields from Eastmoney:

| Field | Screen Label | Meaning |
|-------|--------------|---------|
| `f12` | `Code` | Security code |
| `f14` | `Name` | Security name, used only when ASCII-safe |
| `f2` | `Price` | Latest price |
| `f3` | `Change` | Change percent |
| `f4` | `Change` | Price change |
| `f6` | `Amount` | Turnover amount |
| `f15` | `High` | High |
| `f16` | `Low` | Low |
| `f17` | `Open` | Open |

## Behavior

The script initializes the display, shows a loading screen, fetches quotes at
the configured interval, and keeps the latest successful data on screen if a
later refresh fails. The top card shows readable `Code`, `Price`, `Change`,
`Open`, `High`, `Low`, and `Amount` rows for one security. The bottom list
shows up to two compact `name price percent` rows with extra bottom padding for
small screens.

If startup or HTTP fails, report the `[stock_quotes_display] ERROR: ...` line
directly to the user. If the error mentions allowlist, ask the user to add
`eastmoney.com` or `push2.eastmoney.com` to the HTTP allowlist.
