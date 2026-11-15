"""Mac 창 캡처를 2880×1800 제출본에 앉힌다 — 부드러운 바탕 위 가운데, 그림자. 투명은 남기지 않는다.

    python3 scripts/screenshots/frame_mac.py <창.png> <제출본.png>
"""
import sys
from PIL import Image, ImageDraw, ImageFilter

W, H = 2880, 1800
src, dst = sys.argv[1], sys.argv[2]
win = Image.open(src).convert("RGBA")

# 바탕: 앱 색(파랑)에서 아주 옅게 — 위는 밝고 아래로 조금 짙게
bg = Image.new("RGB", (W, H))
top, bottom = (236, 242, 252), (205, 219, 245)
draw = ImageDraw.Draw(bg)
for y in range(H):
    t = y / (H - 1)
    draw.line([(0, y), (W, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))

# 창은 바탕 안쪽 88% 폭에 맞춘다
scale = min(W * 0.88 / win.width, H * 0.88 / win.height)
win = win.resize((round(win.width * scale), round(win.height * scale)), Image.LANCZOS)
x, y = (W - win.width) // 2, (H - win.height) // 2 + 10

shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
mask = win.split()[3].point(lambda a: 70 if a > 0 else 0)
shadow.paste((20, 40, 90, 255), (x, y + 24), mask)
shadow = shadow.filter(ImageFilter.GaussianBlur(40))
bg = Image.alpha_composite(bg.convert("RGBA"), shadow)
bg.alpha_composite(win, (x, y))
bg.convert("RGB").save(dst, optimize=True)
