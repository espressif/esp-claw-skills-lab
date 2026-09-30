# Steel-string guitar samples

Source instrument: **026-Acoustic Guitar (steel)** from the
[Discord SFZ GM Bank](https://github.com/kinwie/Discord-SFZ-GM-Bank)
(2017 Martin HD28 Vintage Series, recorded by Jeff Learman).

The instrument header dedicates these recordings to **Creative Commons CC0**
(public domain). This Skill imports only that instrument, not the mixed-licence
bank as a whole.

Pinned upstream commit: `7a9c478fe331f94f246d33332f0adedb25bbbe27`

Imported with `tools/import_steel_samples.py`:

- Mono 16-bit PCM at 16 kHz
- WAV headers stripped; runtime loads raw `.pcm` blobs
- Missing semitones are pitch-shifted from the nearest CC0 take in the same
  instrument, as noted in `sample_map.lua`

Attribution is not required by CC0; Jeff Learman and Kinwie are thanked for
making these recordings available.
