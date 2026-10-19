local dir = assert(debug.getinfo(1, "S").source:match("^@(.*/)"))
local runtime = assert(loadfile(dir .. "runtime.lua"))()
local create = assert(loadfile(dir .. "scene.lua"))()
runtime.run("shake_dice", dir .. "..", create)
