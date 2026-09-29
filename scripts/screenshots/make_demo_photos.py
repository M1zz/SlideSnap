#!/usr/bin/env python3
"""스크린샷용 데모 사진 만들기.

slides.py 의 장표를 HTML → 헤드리스 Chrome 으로 그린 뒤, 강의실 스크린에 비친 것처럼
비스듬히 기울이고 흐림·노이즈·앞사람 머리를 얹어 '폰으로 찍은 사진' 을 만든다.
각 발표는 공유 수신함 묶음(사진 + manifest.json)으로 저장되어, 시뮬레이터 App Group 에
넣고 앱을 열면 실제 보정 파이프라인(모서리 감지 → 원근 보정 → 글자 인식)을 거쳐 발표가 된다.

사용법: make_demo_photos.py <ko|en> <출력 폴더>
"""
import html, json, random, subprocess, sys, tempfile, uuid, pathlib
from datetime import datetime, timezone
from PIL import Image, ImageDraw, ImageFilter
import numpy as np

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from slides import DECKS

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
SW, SH = 1600, 900          # 장표 해상도
PW, PH = 2400, 1800         # 사진 해상도 (4:3 가로)


def slide_html(s, accent):
    esc = html.escape
    css = f"""
    *{{margin:0;padding:0;box-sizing:border-box}}
    body{{width:{SW}px;height:{SH}px;background:#fff;font-family:-apple-system,"Apple SD Gothic Neo",sans-serif;color:#1b1b1f;position:relative;overflow:hidden}}
    .bar{{position:absolute;left:0;top:0;width:24px;height:100%;background:{accent}}}
    .pad{{padding:90px 110px 0 130px}}
    h1{{font-size:68px;font-weight:800;letter-spacing:-1px}}
    .rule{{width:120px;height:8px;background:{accent};margin:34px 0 50px;border-radius:4px}}
    li{{font-size:44px;margin:0 0 34px 44px;line-height:1.3}}
    li::marker{{color:{accent}}}
    .foot{{position:absolute;right:60px;bottom:40px;font-size:24px;color:#9a9aa0}}
    """
    k = s["kind"]
    if k == "title":
        body = f"""<div style="position:absolute;inset:0;background:{accent}"></div>
        <div style="position:absolute;left:130px;top:300px;color:#fff">
        <div style="font-size:96px;font-weight:800;letter-spacing:-2px">{esc(s['title'])}</div>
        <div style="font-size:46px;margin-top:40px;opacity:.85">{esc(s['sub'])}</div></div>"""
    elif k == "bullets":
        items = "".join(f"<li>{esc(t)}</li>" for t in s["items"])
        body = f"""<div class="bar"></div><div class="pad"><h1>{esc(s['title'])}</h1><div class="rule"></div><ul>{items}</ul></div>"""
    elif k == "bars":
        mx = max(v for _, v in s["items"])
        rows = "".join(
            f"""<div style="display:flex;align-items:center;margin-bottom:38px">
            <div style="width:330px;font-size:38px">{esc(l)}</div>
            <div style="height:64px;width:{int(820*v/mx)}px;background:{accent};border-radius:10px;opacity:{0.45+0.55*v/mx:.2f}"></div>
            <div style="font-size:38px;margin-left:24px;font-weight:700">{v}</div></div>""" for l, v in s["items"])
        body = f"""<div class="bar"></div><div class="pad"><h1>{esc(s['title'])}</h1><div class="rule"></div>{rows}</div>"""
    elif k == "steps":
        n = len(s["items"])
        cells = "".join(
            f"""<div style="display:flex;flex-direction:column;align-items:center;width:{1300//n}px">
            <div style="width:150px;height:150px;border-radius:75px;background:{accent};color:#fff;font-size:64px;font-weight:800;display:flex;align-items:center;justify-content:center">{i+1}</div>
            <div style="font-size:40px;margin-top:34px;font-weight:600;text-align:center">{esc(t)}</div></div>""" for i, t in enumerate(s["items"]))
        body = f"""<div class="bar"></div><div class="pad"><h1>{esc(s['title'])}</h1><div class="rule"></div>
        <div style="display:flex;margin-top:90px">{cells}</div></div>
        <div style="position:absolute;left:260px;right:260px;top:572px;height:6px;background:{accent};opacity:.25;z-index:-1"></div>"""
    else:  # quote
        q = esc(s["quote"]).replace("\n", "<br>")
        body = f"""<div class="bar"></div><div style="position:absolute;left:170px;top:210px;right:150px">
        <div style="font-size:200px;color:{accent};line-height:.6;font-weight:800">“</div>
        <div style="font-size:70px;font-weight:700;line-height:1.35;margin-top:30px">{q}</div>
        <div style="font-size:40px;color:#77777d;margin-top:50px">— {esc(s['by'])}</div></div>"""
    return f"<!doctype html><html><head><meta charset='utf-8'><style>{css}</style></head><body>{body}</body></html>"


def render_slide(s, accent, out_png, work):
    page = work / (out_png.stem + ".html")
    page.write_text(slide_html(s, accent), encoding="utf-8")
    subprocess.run([CHROME, "--headless=new", f"--screenshot={out_png}", f"--window-size={SW},{SH}",
                    "--force-device-scale-factor=1", "--hide-scrollbars", "--disable-gpu", page.as_uri()],
                   check=True, capture_output=True)


def perspective_coeffs(dst, src):
    """PIL PERSPECTIVE 계수: 출력 좌표(dst 사각형) → 입력 좌표(src 사각형)."""
    A, b = [], []
    for (x, y), (u, v) in zip(dst, src):
        A.append([x, y, 1, 0, 0, 0, -u * x, -u * y]); b.append(u)
        A.append([0, 0, 0, x, y, 1, -v * x, -v * y]); b.append(v)
    return np.linalg.solve(np.array(A, float), np.array(b, float)).tolist()


def photo(slide_png, rng):
    """장표 이미지를 강의실에서 비스듬히 찍은 사진으로."""
    slide = Image.open(slide_png).convert("RGB")
    # 방 배경: 위는 어둡고 스크린 주변만 조금 밝은 벽
    yy, xx = np.mgrid[0:PH, 0:PW]
    cx, cy = PW * rng.uniform(0.47, 0.53), PH * 0.42
    d = np.sqrt(((xx - cx) / PW) ** 2 + ((yy - cy) / PH) ** 2)
    base = np.clip(70 - d * 120, 14, 70)
    bg = np.stack([base * 0.95, base * 0.93, base * 1.05], -1).astype(np.uint8)
    img = Image.fromarray(bg)

    # 스크린 사각형 — 사진마다 조금씩 다른 각도로
    j = lambda s: rng.uniform(-s, s)
    left, right, top, bottom = 360 + j(60), 2040 + j(60), 330 + j(40), 1300 + j(40)
    skew = rng.choice([-1, 1]) * rng.uniform(40, 110)   # 옆자리에서 찍은 사다리꼴
    dst = [(left + j(20), top + skew), (right + j(20), top - skew * 0.6),
           (right + j(20) + 30, bottom + skew * 0.4), (left + j(20) - 20, bottom - skew * 0.3)]
    src = [(0, 0), (SW, 0), (SW, SH), (0, SH)]
    warped = slide.transform((PW, PH), Image.PERSPECTIVE, perspective_coeffs(dst, src), Image.BICUBIC)
    mask = Image.new("L", (PW, PH), 0)
    ImageDraw.Draw(mask).polygon(dst, fill=255)
    # 프로젝터 빛: 살짝 누렇고 가장자리는 어둡게
    tint = Image.new("RGB", (PW, PH), (255, 246, 228))
    warped = Image.blend(warped, Image.composite(tint, warped, Image.new("L", (PW, PH), 40)), 0.5)
    img.paste(warped, (0, 0), mask.filter(ImageFilter.GaussianBlur(1.5)))
    # 스크린 빛 번짐
    glow = mask.filter(ImageFilter.GaussianBlur(60)).point(lambda v: int(v * 0.25))
    img = Image.composite(Image.new("RGB", (PW, PH), (210, 205, 190)), img, glow)
    img.paste(warped, (0, 0), mask.filter(ImageFilter.GaussianBlur(1.5)))

    # 앞사람 머리 실루엣 (스크린 아래쪽만 살짝 가림)
    heads = ImageDraw.Draw(img)
    for _ in range(rng.randint(2, 4)):
        hx, hy, r = rng.uniform(100, PW - 100), PH - rng.uniform(40, 220), rng.uniform(150, 230)
        heads.ellipse([hx - r, hy - r * 1.15, hx + r, hy + r * 1.3], fill=(12, 12, 15))

    # 비네팅 · 초점 흐림 · 센서 노이즈
    v = np.clip(1.05 - d * 0.9, 0.55, 1.0)[..., None]
    arr = np.asarray(img.filter(ImageFilter.GaussianBlur(1.1)), float) * v
    arr += rng.gauss(0, 1) + np.random.default_rng(rng.randint(0, 10**6)).normal(0, 4.5, arr.shape)
    return Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8))


def save_jpeg(img, path, date):
    exif = Image.Exif()
    exif.get_ifd(0x8769)[0x9003] = date   # DateTimeOriginal
    img.save(path, "JPEG", quality=88, exif=exif)


def main(lang, out):
    out = pathlib.Path(out)
    out.mkdir(parents=True, exist_ok=True)
    rng = random.Random(7)
    work = pathlib.Path(tempfile.mkdtemp())
    # 목록 맨 위에 올 발표가 마지막에 처리되도록 역순으로 묶음을 만든다.
    for order, deck in enumerate(reversed(DECKS[lang])):
        batch_id = str(uuid.UUID(int=order + 1))
        bdir = out / "ShareInbox" / batch_id
        bdir.mkdir(parents=True, exist_ok=True)
        files, dates = [], []
        for i, s in enumerate(deck["slides"]):
            png = work / f"{order}-{i}.png"
            render_slide(s, deck["accent"], png, work)
            name = f"{i + 1:04d}.jpg"
            date = deck["date"].format(i=i)
            save_jpeg(photo(png, rng), bdir / name, date)
            files.append(name)
            dates.append(datetime.strptime(date, "%Y:%m:%d %H:%M:%S"))
        # EXIF 시각은 시간대가 없어 앱은 기기 현지 시각으로 읽는다 — 시뮬레이터(=이 Mac)와 맞춘다.
        ref = datetime(2001, 1, 1, tzinfo=timezone.utc).timestamp()
        manifest = {
            "id": batch_id.upper(), "title": deck["title"], "files": files,
            "capturedAt": [d.timestamp() - ref for d in dates],
            "enhance": False, "createdAt": order,
        }
        (bdir / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False))
        print("deck", deck["title"], len(files))
        # 공유 화면 데모용 사진 — 세 번째 발표(데이터 분석)의 원본 사진
        if deck is DECKS[lang][2]:
            share = out / "DemoShare"
            share.mkdir(exist_ok=True)
            for f in files:
                (share / f).write_bytes((bdir / f).read_bytes())


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
