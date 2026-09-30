---
{
  "name": "bilibili_up_fans",
  "description": "Fetch the current Bilibili UP creator fan count through lua_module_call_capability. Defaults to 乐鑫信息科技.",
  "author": "ESP-Claw contributor",
  "metadata":
    {
      "category": ["network"],
      "tags": ["bilibili", "fans", "info"],
      "cap_groups": ["cap_lua", "cap_http_request"]
    }
}
---

# Bilibili UP Fans

Use this skill when the user asks for the fan count of a Bilibili UP creator.

Run the bundled Lua script once with `lua_run_script`. The script uses the Lua
`capability` module from `lua_module_call_capability` to call the registered
`http_request` capability, then extracts `data.card.fans` from Bilibili's card
API response.

By default it fetches the UP creator `乐鑫信息科技`:

```text
https://space.bilibili.com/538078399
```

The configured `search_http_allowlist` must allow `api.bilibili.com` or use `*`.

## Script Args Schema

```json
{
  "type": "object",
  "properties": {
    "mid": {
      "type": "string",
      "description": "Optional Bilibili member id, for example 538078399."
    },
    "url": {
      "type": "string",
      "description": "Optional Bilibili space URL, for example https://space.bilibili.com/538078399."
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
      "description": "Optional source capability name. Defaults to bilibili_up_fans."
    }
  }
}
```

If both `mid` and `url` are provided, `mid` takes precedence.

## Tool Call Inputs

Default action:

```json
{
  "path": "{CUR_SKILL_DIR}/scripts/bilibili_up_fans.lua",
  "args": {}
}
```

Fetch a specific UP creator:

```json
{
  "path": "{CUR_SKILL_DIR}/scripts/bilibili_up_fans.lua",
  "args": {
    "mid": "538078399"
  }
}
```

## Behavior

The script prints a human-readable line and a compact JSON result:

```text
[bilibili_up_fans] 乐鑫信息科技 mid=538078399 fans=54257
{"ok":true,"mid":"538078399","name":"乐鑫信息科技","fans":54257,"url":"https://space.bilibili.com/538078399"}
```

Report the `fans` value to the user. If the script errors, report the error
message directly.
