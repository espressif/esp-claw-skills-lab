-- pairing_adapter.lua: deterministic device-role seam for mosaico-musical.
--
-- This is NOT magnetic pairing and it does not detect any physical link. No
-- provider is wired in, so the shipped Skill always resolves to "solo". The
-- module only defines the contract a future discovery backend must satisfy:
--
--   provider.poll() -> {connected=boolean, local_id=string, peer_id=string}|nil
--
-- The provider is called as `provider.poll(provider)`, so either
-- `function P.poll()` or `function P:poll()` works. IDs may also be numbers;
-- they are coerced with tostring rather than dropped, because an integer
-- device ID is an easy thing for a backend to report.
--
-- Given that report, the two halves split deterministically by string order,
-- so both devices agree on who plays what without exchanging a decision.
-- The tie-break relies on byte ordering: Lua compares strings through
-- strcoll, so a backend whose IDs come from a locale-sensitive source should
-- normalise them (hex, base64, or plain ASCII) before reporting them.

local M = {}

local Adapter = {}
Adapter.__index = Adapter

local SOLO = "solo"
local STRINGS = "strings"
local CHORDS = "chords"

local function clean_id(value)
    if type(value) == "number" then
        value = tostring(value)
    end
    if type(value) ~= "string" or value == "" then
        return nil
    end
    return value
end

-- A provider is untrusted third-party code: any error, any shape, and any
-- partial report degrades to solo rather than taking the instrument down.
local function resolve(provider)
    if type(provider) ~= "table" or type(provider.poll) ~= "function" then
        return SOLO
    end
    -- Passing the receiver keeps colon-defined providers working.
    local ok, report = pcall(provider.poll, provider)
    if not ok or type(report) ~= "table" then
        return SOLO
    end
    if report.connected ~= true then
        return SOLO
    end
    local local_id = clean_id(report.local_id)
    local peer_id = clean_id(report.peer_id)
    if local_id == nil or peer_id == nil or local_id == peer_id then
        return SOLO
    end
    if local_id < peer_id then
        return CHORDS
    end
    return STRINGS
end

function M.new(provider)
    return setmetatable({
        provider = provider,
        current = SOLO,
        -- nil until the first poll, so that poll always reports the role it
        -- resolved at least once.
        last = nil,
    }, Adapter)
end

function Adapter:role()
    return self.current
end

function Adapter:poll()
    local role = resolve(self.provider)
    local changed = role ~= self.last
    self.current = role
    self.last = role
    return role, changed
end

return M
