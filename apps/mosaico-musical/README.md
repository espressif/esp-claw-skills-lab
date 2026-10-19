# Mosaico Musical

Tap the chord area to select a chord, then swipe across the strings to play steel-string guitar samples. Currently designed for solo play on one device.

Launch from the device Launcher. Requires a display 480 pixels high and at least 480 pixels wide, with touch input. Audio requires 16-bit mono or stereo output. Use the device Launcher's back action to exit.

Configure options in `launcher.json.args`; the defaults work without changes. Samples are stored in `assets/steel/` and resampled by the Lua mixer to the device's actual sample rate. Touch handling uses screen snapshots, so intermediate touch positions may be missed during a fast swipe.

Browser play is available; behavior on the physical device still needs verification.

See [ATTRIBUTION](assets/ATTRIBUTION.md) and [LICENSE](LICENSE) for sample sources and licensing.

The browser preview supports touch interaction and runs silently when the simulator has no audio output.
