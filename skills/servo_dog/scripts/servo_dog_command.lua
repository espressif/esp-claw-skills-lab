local json = require("json")
local thread = require("thread")

local sync = thread.sync

local DEFAULT_QUEUE = "servo_dog_cmd"
local raw_args = type(args) == "table" and args or {}
local queue_name = type(raw_args.queue_name) == "string" and raw_args.queue_name ~= "" and raw_args.queue_name or DEFAULT_QUEUE

local function copy_command()
    local command = {}
    for k, v in pairs(raw_args) do
        if k ~= "queue_name" then
            command[k] = v
        end
    end

    if command.action == nil and command.move == nil and command.type == nil and command.name == nil then
        command.action = "idle"
    end
    return command
end

local ok, err = sync.queue_send(queue_name, json.encode(copy_command()), 1000)
if not ok then
    error("[servo_dog] controller is not running; start servo_dog_server.lua first: " .. tostring(err))
end

print("[servo_dog] command sent")
