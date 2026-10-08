---
{
  "name": "github_repo_star",
  "description": "Fetch the current GitHub star count for a repository through lua_module_call_capability. Defaults to https://github.com/espressif/esp-claw.",
  "author": "ESP-Claw contributor",
  "metadata":
    {
      "category": ["utility"],
      "tags": ["github", "stars", "info"],
      "cap_groups": ["cap_lua", "cap_http_request"]
    }
}
---

# GitHub Repository Star

Use this skill when the user asks for the star count of a GitHub repository.

Run the bundled Lua script once with `lua_run_script`. The script uses the Lua
`capability` module from `lua_module_call_capability` to call the registered
`http_request` capability, then extracts `stargazers_count` from the GitHub REST
API response.

By default it fetches:

```text
https://github.com/espressif/esp-claw
```

The configured `search_http_allowlist` must allow `api.github.com` or use `*`.

## Script Args Schema

```json
{
  "type": "object",
  "properties": {
    "repo": {
      "type": "string",
      "description": "Optional GitHub repository as owner/name, for example espressif/esp-claw."
    },
    "url": {
      "type": "string",
      "description": "Optional GitHub repository URL, for example https://github.com/espressif/esp-claw."
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
      "description": "Optional source capability name. Defaults to github_repo_star."
    }
  }
}
```

If both `repo` and `url` are provided, `repo` takes precedence.

## Tool Call Inputs

Default action:

```json
{
  "path": "{CUR_SKILL_DIR}/scripts/github_repo_star.lua",
  "args": {}
}
```

Fetch a specific repository:

```json
{
  "path": "{CUR_SKILL_DIR}/scripts/github_repo_star.lua",
  "args": {
    "repo": "espressif/esp-idf"
  }
}
```

## Behavior

The script prints a human-readable line and a compact JSON result:

```text
[github_repo_star] espressif/esp-claw stars=12345 url=https://github.com/espressif/esp-claw
{"ok":true,"owner":"espressif","repo":"esp-claw","full_name":"espressif/esp-claw","stars":12345,"url":"https://github.com/espressif/esp-claw"}
```

Report the `stars` value to the user. If the script errors, report the error
message directly.
