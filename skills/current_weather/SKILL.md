---
{
  "name": "current_weather",
  "description": "Fetch current weather through lua_module_call_capability and https://api.open-meteo.com. Defaults to Singapore.",
  "author": "ESP-Claw contributor",
  "metadata":
    {
      "category": ["utility"],
      "tags": ["weather", "info"],
      "cap_groups": ["cap_lua", "cap_http_request"]
    }
}
---

# Current Weather

Use this skill when the user asks for current weather, temperature, wind,
humidity, rain probability, or today's weather forecast.

Run the bundled Lua script once with `lua_run_script`. The script uses the Lua
`capability` module from `lua_module_call_capability` to call the registered
`http_request` capability against Open-Meteo's forecast API at
`https://api.open-meteo.com`.

By default it fetches weather for:

```text
Singapore (1.3521, 103.8198)
```

The configured `search_http_allowlist` must allow `api.open-meteo.com` or use
`*`.

## Script Args Schema

```json
{
  "type": "object",
  "properties": {
    "latitude": {
      "type": "number",
      "description": "Optional latitude. Defaults to Singapore latitude 1.3521."
    },
    "longitude": {
      "type": "number",
      "description": "Optional longitude. Defaults to Singapore longitude 103.8198."
    },
    "location": {
      "type": "string",
      "description": "Optional display label for the requested coordinates. Defaults to Singapore."
    },
    "timezone": {
      "type": "string",
      "description": "Optional Open-Meteo timezone parameter. Defaults to auto."
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
      "description": "Optional source capability name. Defaults to current_weather."
    }
  }
}
```

## Tool Call Inputs

Default action:

```json
{
  "path": "{CUR_SKILL_DIR}/scripts/current_weather.lua",
  "args": {}
}
```

Fetch weather for a specific coordinate:

```json
{
  "path": "{CUR_SKILL_DIR}/scripts/current_weather.lua",
  "args": {
    "location": "Shanghai",
    "latitude": 31.2304,
    "longitude": 121.4737
  }
}
```

## Behavior

The script prints a human-readable line and a compact JSON result:

```text
[current_weather] Singapore temp=29.4C apparent=34.1C condition=Partly cloudy humidity=78% wind=8.5km/h rain_prob=35% time=2026-05-13T14:00
{"ok":true,"location":"Singapore","latitude":1.3521,"longitude":103.8198,"temperature_c":29.4,"apparent_temperature_c":34.1,"relative_humidity_pct":78,"wind_speed_kmh":8.5,"weather_code":2,"condition":"Partly cloudy","rain_probability_pct":35,"daily_high_c":31.2,"daily_low_c":26.7,"time":"2026-05-13T14:00"}
```

Report the weather values to the user. If the script errors, report the error
message directly.
