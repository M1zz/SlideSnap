#!/usr/bin/env python3
"""앱스토어 제출본 만들기: 원본 캡처(docs/screenshots/raw/<언어>/) 위에 헤드라인과 기기 목업을 얹는다.

HTML 템플릿 → 헤드리스 Chrome 렌더링. 결과는 docs/screenshots/marketing/<언어>/ (1242×2688) —
DeployBar 가 배포할 때 이 폴더를 언어별로 App Store Connect 에 올린다.

사용법: scripts/screenshots/make_marketing.py [ko|en ...]   (원본은 make_screenshots.sh 로 먼저 찍는다)
"""
import subprocess, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parents[2]
RAW = ROOT / "docs" / "screenshots" / "raw"
OUT = ROOT / "docs" / "screenshots" / "marketing"
WORK = pathlib.Path("/tmp") / "slidesnap-marketing"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
W, H = 1242, 2688   # App Store 제출 규격 (6.5")

# (파일, 레이아웃, 헤드라인, 서브카피) — 파일 이름 순서가 스토어에 보이는 순서
SHOTS = {
    "ko": [
        ("01-share.png",  "hero-bleed",  "사진 앱에서 골라<br>바로 발표 자료로", "여러 장을 공유하면 하나로 정리돼요"),
        ("02-list.png",   "left-text",   "강의 장표를<br>발표별로 한눈에", "찍은 장표가 자동으로 묶여요"),
        ("03-slide.png",  "before-after", "비스듬히 찍어도<br>반듯하게", "모서리를 찾아 자동으로 펴 드려요"),
        ("04-detail.png", "text-bottom", "필기 대신 찍고<br>PDF로 정리", "모은 장표를 복습용 PDF로 내보내요"),
        ("05-search.png", "dark",        "장표 속 글자까지<br>검색", "기억나는 단어 하나면 충분해요"),
    ],
    "en": [
        ("01-share.png",  "hero-bleed",  "From Photos<br>to a deck", "Share several photos, get one tidy deck"),
        ("02-list.png",   "left-text",   "Every lecture,<br>neatly filed", "Slides are grouped by session"),
        ("03-slide.png",  "before-after", "Shot at an angle?<br>Straightened.", "Edges found and corrected for you"),
        ("04-detail.png", "text-bottom", "Snap instead<br>of scribbling", "Export your slides as a study PDF"),
        ("05-search.png", "dark",        "Search the words<br>on your slides", "One word is all it takes"),
    ],
}

BASE_CSS = f"""
* {{ margin:0; padding:0; box-sizing:border-box; }}
html,body {{ width:{W}px; height:{H}px; overflow:hidden; }}
body {{ background:#f4f4f5; font-family:-apple-system, "Apple SD Gothic Neo", sans-serif; position:relative; }}
.headline {{ font-size:100px; font-weight:800; color:#141416; letter-spacing:-2px; line-height:1.25; }}
.sub {{ font-size:52px; font-weight:500; color:#9a9aa0; letter-spacing:-1px; }}
.phone {{ background:#17171a; border-radius:116px; border:3px solid #3a3a3e; padding:25px;
  box-shadow: 60px 90px 120px rgba(0,0,0,.28), 20px 30px 50px rgba(0,0,0,.18); }}
.phone img {{ width:100%; display:block; border-radius:92px; }}
"""

LAYOUTS = {
    # 1) 정면 대형, 하단 블리드
    "hero-bleed": """
.headline { text-align:center; margin-top:290px; padding:0 70px; }
.sub { text-align:center; margin-top:52px; }
.wrap { display:flex; justify-content:center; margin-top:150px; }
.phone { width:1000px; }
""",
    # 2) 좌측 정렬 텍스트 + 오른쪽 기울기, 오른쪽 블리드
    "left-text": """
.headline { text-align:left; margin:300px 0 0 110px; }
.sub { text-align:left; margin:48px 0 0 114px; }
.wrap { perspective:2600px; perspective-origin:30% 30%; position:absolute; left:300px; top:990px; }
.phone { width:840px; transform:rotateY(16deg) rotateX(2deg); }
""",
    # 3) 폰 상단, 텍스트 하단
    "text-bottom": """
.wrap { perspective:2800px; perspective-origin:50% 40%; display:flex; justify-content:center; margin-top:170px; }
.phone { width:880px; transform:rotateY(-10deg) rotateX(2deg); }
.headline { text-align:center; margin-top:120px; padding:0 70px; }
.sub { text-align:center; margin-top:48px; }
""",
    # 4) 평면 회전, 좌측 치우침 + 하단 블리드
    "flat-rotate": """
.headline { text-align:center; margin-top:270px; padding:0 70px; }
.sub { text-align:center; margin-top:52px; }
.wrap { position:absolute; left:120px; top:1010px; }
.phone { width:1010px; transform:rotate(-6deg); }
""",
    # 6) 보정 전후: 정면 폰(보정된 장표) 위에 비스듬히 찍힌 원본 사진 카드를 겹친다
    "before-after": """
.headline { text-align:center; margin-top:290px; padding:0 70px; }
.sub { text-align:center; margin-top:52px; }
.wrap { display:flex; justify-content:center; margin-top:150px; }
.phone { width:960px; }
.before { position:absolute; left:70px; top:1020px; width:700px; transform:rotate(-7deg);
  background:#fff; padding:18px; border-radius:22px; box-shadow:30px 50px 90px rgba(0,0,0,.35); }
.before img { width:100%; display:block; border-radius:10px; }
""",
    # 5) 다크 배경 반전 + 정면
    "dark": """
body { background:#131316; }
.headline { color:#f5f5f7; text-align:center; margin-top:290px; padding:0 70px; }
.sub { color:#77777d; text-align:center; margin-top:52px; }
.wrap { display:flex; justify-content:center; margin-top:150px; }
.phone { width:930px; border-color:#48484e;
  box-shadow: 0 0 160px rgba(80,140,255,.22), 40px 70px 110px rgba(0,0,0,.55); }
""",
}

# text-bottom 은 폰이 먼저 오는 DOM 순서
BODY_TEXT_FIRST = '<div class="headline">{headline}</div><div class="sub">{sub}</div><div class="wrap"><div class="phone"><img src="{img}"></div></div>'
BODY_PHONE_FIRST = '<div class="wrap"><div class="phone"><img src="{img}"></div></div><div class="headline">{headline}</div><div class="sub">{sub}</div>'

HTML = """<!doctype html><html><head><meta charset="utf-8"><style>
{base}{layout}
</style></head><body>{body}</body></html>"""

def main(langs):
    WORK.mkdir(exist_ok=True)
    for lang in langs:
        out_dir = OUT / lang
        out_dir.mkdir(parents=True, exist_ok=True)
        for fname, layout, headline, sub in SHOTS[lang]:
            body_tpl = BODY_PHONE_FIRST if layout == "text-bottom" else BODY_TEXT_FIRST
            raw = RAW / lang / fname
            body = body_tpl.format(headline=headline, sub=sub, img=raw.as_uri())
            if layout == "before-after":
                body += f'<div class="before"><img src="{(RAW / lang / "before.jpg").as_uri()}"></div>'
            html_path = WORK / f"{lang}-{fname.replace('.png', '.html')}"
            html_path.write_text(HTML.format(base=BASE_CSS, layout=LAYOUTS[layout], body=body), encoding="utf-8")
            out_png = out_dir / fname
            subprocess.run([CHROME, "--headless=new", f"--screenshot={out_png}",
                            f"--window-size={W},{H}", "--force-device-scale-factor=1",
                            "--hide-scrollbars", "--disable-gpu", html_path.as_uri()],
                           check=True, capture_output=True)
            print(f"rendered {out_png.relative_to(ROOT)}")


if __name__ == "__main__":
    main(sys.argv[1:] or list(SHOTS))
