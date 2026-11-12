-- Icon names used by the pages, mapped to glyphs of the system font (lvgl.SYMBOL).
local lvgl = require("lvgl")

local S = assert(lvgl.SYMBOL, "Infrared Remote needs firmware with lvgl.SYMBOL icons")

return {
    back = S.LEFT,
    plus = S.PLUS,
    minus = S.MINUS,
    check = S.OK,
    chevron_up = S.UP,
    chevron_down = S.DOWN,
    chevron_left = S.LEFT,
    chevron_right = S.RIGHT,
    power = S.POWER,
    settings = S.SLIDERS_H,
    trash = S.TRASH,
    learn = S.SATELLITE_DISH,
    remote = S.MOBILE_ALT,
    tv = S.TV,
    snow = S.SNOWFLAKE,
    play = S.PLAY,
    play_pause = S.PLAY .. S.PAUSE,
    previous = S.PREV,
    next = S.NEXT,
    grid = S.TH_LARGE,
    vol_up = S.VOLUME_MAX,
    vol_down = S.VOLUME_MID,
    mute = S.VOLUME_MUTE,
    input = S.SIGN_IN_ALT,
    home = S.HOME,
    ret = S.REPLY,
    sun = S.SUN,
    drop = S.TINT,
    -- The font's own letter keeps "auto" in the same style as the glyphs around it.
    auto = "A",
    fan = S.WIND,
    swing = S.ARROWS_ALT_V,
}
