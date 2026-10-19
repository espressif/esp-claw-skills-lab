# Jump Prince

Launch from the device Launcher to play the original levels and pixel sprites rendered with LVGL.

Hold Left / Jump / Right at the bottom to charge a jump, then release to leap. Touch targets extend above the buttons. Sliding after a press does not change direction. Each button shows its own charge bar. The top bar displays the level number and provides pause, resume, restart, and exit controls. Pausing cancels the current charge so resuming does not trigger an accidental jump.

Optional settings in `launcher.json.args`: `assets_dir` selects the sprite directory; `tile_px` sets an integer tile size that must fit entirely within the display area. By default, the App uses bundled assets and adapts to the screen.

Requires recent Lua LVGL firmware with object-flag and bring-to-front APIs. Browser play is available; display rendering and touch feel still need verification on the physical device.
