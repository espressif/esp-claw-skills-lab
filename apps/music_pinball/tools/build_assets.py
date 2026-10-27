from pathlib import Path
import math, struct
from PIL import Image, ImageDraw
root = Path(__file__).resolve().parents[1] / 'assets'
for name, duration in [('pluck', .45), ('kick', .10), ('chime', .30)]:
    data = []
    for i in range(round(16000 * duration)):
        t = i / 16000
        if name == 'pluck':
            v = sum(math.sin(2 * math.pi * 261.625565 * h * t) * math.exp(-t * (7 + h * 2)) / h**1.7 for h in range(1, 6)) * .58
        elif name == 'kick':
            v = .6 * math.sin(2 * math.pi * (110 * t + 3 * (1 - math.exp(-t * 35)))) * math.exp(-t * 45)
        else:
            v = sum(math.sin(2 * math.pi * f * t) for f in [523.251, 659.255, 783.991]) * .20 * math.exp(-t * 12)
        envelope = min(1, t / .002, (duration - t) / .012)
        data.append(round(max(-1, min(1, v * envelope)) * 32767))
    (root / (name + '.pcm')).write_bytes(struct.pack('<' + 'h' * len(data), *data))
im = Image.new('RGB', (192, 192), '#091522'); d = ImageDraw.Draw(im)
d.rounded_rectangle((17, 13, 175, 179), radius=35, outline='#315365', width=5)
for x,y,c in [(65,65,'#63E9DF'),(127,65,'#F28CAE'),(96,105,'#FFC778')]:
    d.ellipse((x-18,y-18,x+18,y+18), fill='#102739', outline=c,width=4)
    d.line((x+3,y-7,x+3,y+5),fill=c,width=3); d.ellipse((x-5,y+2,x+3,y+8),fill=c)
d.line((47,147,82,157),fill='#63E9DF',width=10); d.line((145,147,110,135),fill='#F28CAE',width=10)
d.ellipse((130,104,146,120),fill='#F0F7F4')
im.resize((48,48),Image.LANCZOS).save(root/'icon.jpg',quality=95)
