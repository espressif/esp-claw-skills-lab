-- token_usage.lua
-- Entry point for lua_run_script_async. Must stay under 64 KiB; logic lives in sibling modules.
local dashboard = require("token_usage_dashboard")

dashboard.run(type(args) == "table" and args or {})
