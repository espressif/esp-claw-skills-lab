---
{
  "name": "current_ip_info",
  "description": "Fetch the current public IP geolocation information through lua_module_call_capability and https://ipinfo.io/json.",
  "author": "ESP-Claw contributor",
  "metadata":
    {
      "category": ["network"],
      "tags": ["ip"],
      "cap_groups": ["cap_lua", "cap_http_request"]
    }
}
---

# Current IP Info

Use this skill when the user asks for the current public IP address, IP
geolocation, network location, city, region, country, ISP, or ASN.

Run the bundled Lua script once with `lua_run_script`. The script uses the Lua
`capability` module from `lua_module_call_capability` to call the registered
`http_request` capability against `https://ipinfo.io/json`.

The configured `search_http_allowlist` must allow `ipinfo.io` or use `*`.

## Script Args Schema

```json
{
  "type": "object",
  "properties": {
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
      "description": "Optional source capability name. Defaults to current_ip_info."
    }
  }
}
```

## Tool Call Inputs

Default action:

```json
{
  "path": "{CUR_SKILL_DIR}/scripts/current_ip_info.lua",
  "args": {}
}
```

## Behavior

The script prints a human-readable line and a compact JSON result:

```text
[current_ip_info] ip=203.0.113.10 city=Singapore region=Singapore country=SG loc=1.3521,103.8198 org=AS00000 Example Network
{"ok":true,"ip":"203.0.113.10","city":"Singapore","region":"Singapore","country":"SG","loc":"1.3521,103.8198","latitude":1.3521,"longitude":103.8198,"org":"AS00000 Example Network","timezone":"Asia/Singapore"}
```

Report the IP geolocation values to the user. If the script errors, report the
error message directly.
