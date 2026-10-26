"""Build the Chinese UI subset from a local Noto Sans CJK TTC (requires Pillow)."""
import struct
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

output = Path(__file__).resolve().parents[1] / "assets"
scripts = output.parent / "scripts"
text = "".join(path.read_text() for path in scripts.glob("*.lua"))
codepoints = sorted(set(range(32, 127)) | {ord(c) for c in text if ord(c) > 127})
for size in (20,):
    font = ImageFont.truetype(sys.argv[1], size, index=2)
    boxes = [font.getbbox(chr(cp), anchor="ls") for cp in codepoints]
    ascent = max(-box[1] for box in boxes)
    descent = max(box[3] for box in boxes)
    records, pixels = bytearray(), bytearray()
    for cp in codepoints:
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
    header = struct.pack("<4shhhHII", b"DFN1", ascent, descent, round(font.getlength("M")), 0, len(codepoints), ord("?"))
    (output / f"ui-{size}.dfn").write_bytes(header + records + pixels)
