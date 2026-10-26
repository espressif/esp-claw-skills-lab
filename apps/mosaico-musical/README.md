# Mosaico Musical

Tap the chord area to select a chord, then swipe across the strings to play steel-string guitar samples. Currently designed for solo play on one device.

Launch from the device Launcher. Requires a display at least 360 pixels wide and 360 pixels high (including 360×360 vocat and 480×480 Mosaico), with touch input. Audio requires firmware with the native `audio.sample_player` API. Use the device Launcher's back action to exit.

Configure options in `launcher.json.args`; the defaults work without changes. Samples are stored in `assets/steel/`. A native worker mixes the 16 kHz mono bank and converts the mixed signal to the device output format; Lua only submits note events. Touch handling uses screen snapshots, so intermediate touch positions may be missed during a fast swipe.

Browser preview is available. The native audio path is validated on the 360×360 vocat device.

See [ATTRIBUTION](assets/ATTRIBUTION.md) and [LICENSE](LICENSE) for sample sources and licensing.

The browser preview supports touch interaction and runs silently when the simulator has no audio output.
