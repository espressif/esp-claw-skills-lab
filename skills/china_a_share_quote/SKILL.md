---
{
  "name": "china_a_share_quote",
  "description": "Fetch China A-share stock quote information through lua_module_call_capability and https://qt.gtimg.cn. Defaults to sh688018.",
  "author": "ESP-Claw contributor",
  "metadata":
    {
      "category": ["network"],
      "tags": ["share", "stock", "info"],
      "cap_groups": ["cap_lua", "cap_http_request"]
    }
}
---

# China A-Share Quote

Use this skill when the user asks for current China A-share stock information.

Run the bundled Lua script once with `lua_run_script`. The script uses the Lua
`capability` module from `lua_module_call_capability` to call the registered
`http_request` capability against Tencent's quote API at `https://qt.gtimg.cn`.

By default it fetches:

```text
sh688018
```

The configured `search_http_allowlist` must allow `qt.gtimg.cn` or use `*`.

## Script Args Schema

```json
{
  "type": "object",
  "properties": {
    "symbol": {
      "type": "string",
      "description": "Optional Tencent quote symbol, for example sh688018 or sz000001."
    },
    "timeout_ms": {
      "type": "integer",
      "description": "Optional HTTP timeout in milliseconds. Defaults to 15000."
    },
    "session_id": {
      "type": "string",
      "description": "Optional session id passed to capability.call opts."
    },
    "source_cap": {
      "type": "string",
      "description": "Optional source capability name. Defaults to china_a_share_quote."
    }
  }
}
```

## Tool Call Inputs

Default action:

```json
{
  "path": "{CUR_SKILL_DIR}/scripts/china_a_share_quote.lua",
  "args": {}
}
```

Fetch a specific stock:

```json
{
  "path": "{CUR_SKILL_DIR}/scripts/china_a_share_quote.lua",
  "args": {
    "symbol": "sz000001"
  }
}
```

## Behavior

The script prints a human-readable line and a compact JSON result:

```text
[china_a_share_quote] sh688018 price=179.73 change=5.80 pct=3.33% high=183.83 low=168.19 time=20260513161436
{"ok":true,"symbol":"sh688018","code":"688018","price":179.73,"change":5.8,"change_pct":3.33,"open":172,"previous_close":173.93,"high":183.83,"low":168.19,"volume":7435981,"amount":130946,"datetime":"20260513161436"}
```

Report the quote values to the user. If the script errors, report the error
message directly.
