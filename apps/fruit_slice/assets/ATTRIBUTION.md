# Asset credits

- Fruit illustrations and launcher icon: original artwork generated with OpenAI image generation for Fruit Slice, October 2026. Artwork was compiled into small RGB565 sprite strips for the device; transparent areas are omitted.
- Sprite files (`.spr`): `FSP1`, little-endian uint16 width, height, and strip count, followed by each strip's uint16 x, y, width, height and packed little-endian RGB565 pixels. Edge pixels are blended against the App's ink background. No runtime image decoder is required.
- Music and sound effects: original synthesized plucked notes, filtered noise, and percussion created for this App. The twelve-second menu loop uses mono AAC at 22,050 Hz. Gameplay effects use preloaded signed 16-bit little-endian mono PCM at 16,000 Hz, streamed to the firmware mixer without starting a media decoder on each hit.
- Fonts (`ui-*.dfn`): ASCII bitmap subsets of Lato Bold, distributed under the SIL Open Font License 1.1. See [FONT-LICENSE.txt](FONT-LICENSE.txt).

All runtime assets are included in this package. No external asset service or cross-App dependency is needed.
