---
{
  "name": "weather_clock",
  "description": "Show a live clock and current/two-day weather forecast on the board display. Defaults to Shanghai; supports another city. Requires a Seniverse API key and HTTP allowlist for api.seniverse.com.",
  "author": "ESP-Claw contributor",
  "metadata": {
    "cap_groups": ["cap_lua", "cap_http_request"],
    "manage_mode": "web",
    "category": ["utility"],
    "peripherals": ["display"],
    "tags": ["weather", "clock", "seniverse", "forecast"]
  }
}
---

# Weather Clock

Use this skill when the user wants the device screen to show the current time and weather.

The skill uses Seniverse (Xinzhi Weather) APIs. Seniverse requires an API key. Use plain `http://api.seniverse.com` endpoints so it can run on builds where HTTPS/TLS requests are not available. The device HTTP allowlist must allow `api.seniverse.com`.

Before starting or switching Weather Clock, make sure the user has a Seniverse API key. If the user has not provided one, guide them to register or log in at `https://www.seniverse.com`, open the Seniverse console/API key page, copy the API key, and send it back. Do not invent an API key.

The script stores the Seniverse API key together with the selected location in the DATA-root file `weather_clock/config.json`. On the next startup, it automatically reads `weather_clock/config.json` and reuses the saved `api_key`, location, and timezone. Do not create a separate API-key file.

Every weather call must explicitly tell the device both:

- `api_key`: the user's Seniverse API key.
- `location`: the queried location, preferably an ASCII city name or Seniverse city V3 ID.

Do not use latitude and longitude for Seniverse requests. Seniverse weather APIs use the `location` parameter.

## Start Weather Clock

Run the controller asynchronously because it owns the display and refreshes continuously:

```json
{"path":"{CUR_SKILL_DIR}/scripts/start_weather_clock.lua","args":{"api_key":"<SENIVERSE_API_KEY>","location":"Shanghai"},"timeout_ms":0,"name":"weather_clock","exclusive":"display","replace":true,"log_bytes":4096}
```

Starting this async script is the only Lua tool call needed to start Weather Clock. The script starts local control endpoints at `/api/lua/weather_clock/control` and `/api/lua/weather_clock/icon`, and calls Seniverse internally through Lua `capability.call("http_request", ...)`. Do not claim the weather has already been fetched just because the async job started; say that Weather Clock is running and will fetch Seniverse data in the background. To verify the fetch, inspect the async job log for lines such as `[weather_clock] HTTP Seniverse now`, `[weather_clock] HTTP Seniverse daily`, and `[weather_clock] weather updated`.

By default it uses Shanghai:

```json
{"location":"Shanghai","timezone":"Asia/Shanghai"}
```

To start Weather Clock directly on another city when it is not already running, pass the API key and queried location:

```json
{"path":"{CUR_SKILL_DIR}/scripts/start_weather_clock.lua","args":{"mode":"switch","api_key":"<SENIVERSE_API_KEY>","location":"Beijing","timezone":"Asia/Shanghai"},"timeout_ms":0,"name":"weather_clock","exclusive":"display","replace":true,"log_bytes":4096}
```

When starting directly, use a Seniverse city V3 ID when available:

```json
{"path":"{CUR_SKILL_DIR}/scripts/start_weather_clock.lua","args":{"mode":"switch","api_key":"<SENIVERSE_API_KEY>","location":"WX4FBXXFKE4F","timezone":"Asia/Shanghai"},"timeout_ms":0,"name":"weather_clock","exclusive":"display","replace":true,"log_bytes":4096}
```

## Control Location

When the user asks to change the city/location or query a city's weather while Weather Clock is running, do not run any Lua script and do not replace the display job. Send an HTTP POST to the local Weather Clock control endpoint instead. This lets the currently running Weather Clock page call Seniverse and redraw its existing LVGL UI in place.

Local control endpoint:

```json
{"url":"http://127.0.0.1/api/lua/weather_clock/control","method":"POST","headers":{"Content-Type":"application/json"},"body":"{\"mode\":\"switch\",\"api_key\":\"<SENIVERSE_API_KEY>\",\"location\":\"Beijing\",\"timezone\":\"Asia/Shanghai\"}","timeout_ms":15000,"max_body_bytes":1024}
```

Use `mode: "switch"` when the user asks to switch/change the current city. This changes the stored default and updates the current screen in place:

```json
{"url":"http://127.0.0.1/api/lua/weather_clock/control","method":"POST","headers":{"Content-Type":"application/json"},"body":"{\"mode\":\"switch\",\"api_key\":\"<SENIVERSE_API_KEY>\",\"location\":\"Beijing\",\"timezone\":\"Asia/Shanghai\"}","timeout_ms":15000,"max_body_bytes":1024}
```

Use `mode: "query"` when the user asks to query/check a city without saying to switch the current default. This displays the queried weather on the current screen but does not change the stored default:

```json
{"url":"http://127.0.0.1/api/lua/weather_clock/control","method":"POST","headers":{"Content-Type":"application/json"},"body":"{\"mode\":\"query\",\"api_key\":\"<SENIVERSE_API_KEY>\",\"location\":\"Beijing\",\"timezone\":\"Asia/Shanghai\"}","timeout_ms":15000,"max_body_bytes":1024}
```

Use an ASCII city name for `location` unless the user provides a Seniverse city V3 ID. If the user gives a non-ASCII city name, translate it to an English city name before calling the script, for example use `Beijing` for `北京`.

Before calling the script, tell the user which Seniverse API key status and location will be sent to the device, for example: `Using Seniverse API key: provided; location: Beijing`. Do not print the full API key back to the user unless they explicitly ask.

For the most reliable result, include the Seniverse city V3 ID:

```json
{"url":"http://127.0.0.1/api/lua/weather_clock/control","method":"POST","headers":{"Content-Type":"application/json"},"body":"{\"mode\":\"switch\",\"api_key\":\"<SENIVERSE_API_KEY>\",\"location\":\"WX4FBXXFKE4F\",\"timezone\":\"Asia/Shanghai\"}","timeout_ms":15000,"max_body_bytes":1024}
```

If the HTTP POST returns connection refused or 404, Weather Clock is not running yet. Start `start_weather_clock.lua` asynchronously once, then retry the local control POST.

After a `switch` or `query` control POST, report that the request was sent to Weather Clock, not that the HTTP fetch is complete unless the async job log confirms it.

## Set Weather Icon

When the user wants to manually test or change the weather icon while Weather Clock is running, do not run a Lua script. Send an HTTP POST to the local icon endpoint:

```json
{"url":"http://127.0.0.1/api/lua/weather_clock/icon","method":"POST","headers":{"Content-Type":"application/json"},"body":"{\"icon\":\"rain\"}","timeout_ms":15000,"max_body_bytes":1024}
```

Valid icon values:

- `clear`
- `cloudy`
- `partly`
- `rain`
- `thunder`
- `snow`
- `wind`
- `fog`
- `night`
- `auto`

Aliases are accepted for common names such as `sunny`, `cloud`, `rainy`, `thunderstorm`, `snowy`, `windy`, `foggy`, and `partly_cloudy`.

Sending `auto` clears the manual icon override and returns to the icon selected from the latest weather API result:

```json
{"url":"http://127.0.0.1/api/lua/weather_clock/icon","method":"POST","headers":{"Content-Type":"application/json"},"body":"{\"icon\":\"auto\"}","timeout_ms":15000,"max_body_bytes":1024}
```

The icon endpoint changes only the icon. It does not change city, weather text, temperature, date, or stored default settings. Automatic weather updates use the same LVGL icon drawing function with the icon kind mapped from Seniverse weather codes.

## Behavior

- The clock reads local device time through `system.date`, which uses the system time synchronized by SNTP after Wi-Fi connects.
- The clock label refreshes once per second and displays time down to minutes.
- Weather refreshes immediately at startup and then once every hour.
- Switch requests store the Seniverse API key and location in `weather_clock/config.json` under the DATA root.
- Startup automatically reads `weather_clock/config.json` and reuses the saved API key and location.
- Query requests display the requested location without changing the stored default.
- The default forecast covers today and tomorrow.
- Screen text is ASCII-only. Temperature uses a `C` label with a small LVGL-drawn dot near its upper-left instead of the `°` character.
- If using a free Seniverse account, follow Seniverse's attribution requirement when displaying weather data.
- Weather icons are drawn with LVGL objects and line widgets, not loaded as bitmap image files.
- Seniverse weather codes are mapped to clear, cloudy, partly cloudy, rain, thunderstorm, snow, wind, night, and fog icons.
- If time is not synchronized yet, the display keeps running and shows a waiting status until `system.date` becomes available.
