# Snake

Guide a mint-green snake toward orange fruit on a dark board. The top bar shows your current score and the best score from this session; buttons on the right pause, resume, and exit.

- Tap or swipe on the board to start. Swipe during play to turn; reversing direction directly is not allowed.
- When paused, tap the board or resume button to continue. After game over, tap or swipe to restart.
- Eating fruit increases your score and gradually speeds up the snake. Hitting a wall or your own body ends the game. Fill the board to win.

Launch from the device Launcher. Requires a touch display of at least 160×160; a speaker is optional. A silent browser simulator is available.

Set options in `launcher.json.args`: `grid_size` controls the number of cells along the shorter side (default 15, range 12–30); `target_size` limits the board's longest edge (fills the available screen by default); `run_time_ms` sets runtime in milliseconds (`0` for continuous play). Cells remain square, and the longer side's cell count adapts to the screen's aspect ratio.

The interface uses the current `display` API and `display.load_font()`. Fonts load on demand and are released on exit. Static screens do not redraw continuously. `assets/ui-*.dfn` contains ASCII bitmap subsets of Lato Bold; see `assets/FONT-LICENSE.txt`. To regenerate them, run the following in a Python environment with Pillow installed:

```sh
python3 apps/snake_game/tools/build_fonts.py /path/to/Lato-Bold.ttf
```
