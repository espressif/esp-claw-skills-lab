"""Build compact DFN1 fonts from a local Lato Bold TTF (requires Pillow)."""
import struct
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

output = Path(__file__).resolve().parents[1] / "assets"
for size in (12, 18, 24, 36, 48):
    font = ImageFont.truetype(sys.argv[1], size)
    boxes = [font.getbbox(chr(cp), anchor="ls") for cp in range(32, 127)]
    ascent = max(-box[1] for box in boxes)
    descent = max(box[3] for box in boxes)
    records, pixels = bytearray(), bytearray()
    for cp in range(32, 127):
        char = chr(cp)
        left, top, right, bottom = font.getbbox(char, anchor="ls")
        width, height = right - left, bottom - top
        if not width or not height:
            width = height = left = top = bottom = 0
        records += struct.pack("<IIhhhHH", cp, len(pixels), round(font.getlength(char)), left, -bottom, width, height)
        if width:
            bitmap = Image.new("1", (width, height))
            ImageDraw.Draw(bitmap).text((-left, -top), char, font=font, fill=1, anchor="ls")
            pixels += bitmap.tobytes()
    header = struct.pack("<4shhhHII", b"DFN1", ascent, descent, round(font.getlength("M")), 0, 95, ord("?"))
    (output / f"ui-{size}.dfn").write_bytes(header + records + pixels)
