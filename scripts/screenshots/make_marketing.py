#!/usr/bin/env python3
"""앱스토어 제출본 만들기: 원본 캡처(docs/screenshots/raw/<언어>/) 위에 헤드라인과 기기 목업을 얹는다.

HTML 템플릿 → 헤드리스 Chrome 렌더링. 결과는 docs/screenshots/marketing/<언어>/ (1242×2688) —
DeployBar 가 배포할 때 이 폴더를 언어별로 App Store Connect 에 올린다.

사용법: scripts/screenshots/make_marketing.py [ko|en ...]   (원본은 make_screenshots.sh 로 먼저 찍는다)
       KIND=duo scripts/screenshots/make_marketing.py ...  아이폰 듀오 바깥 화면: raw/duo/<언어>/ → marketing/<언어>/duo-….png (1398×2034)
       같은 언어 폴더에 아이폰과 같이 둔다. DeployBar 가 픽셀 크기로 듀오 칸을 가른다.
"""
import subprocess, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parents[2]
RAW = ROOT / "docs" / "screenshots" / "raw"
OUT = ROOT / "docs" / "screenshots" / "marketing"
WORK = pathlib.Path("/tmp") / "slidesnap-marketing"
# 다른 작업이 Chrome 을 같이 쓰면 느리거나 멈춘다 — CHROME 환경 변수로 chrome-headless-shell 등을 쓸 수 있다.
import os
CHROME = os.environ.get("CHROME", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
DUO = os.environ.get("KIND") == "duo"
if DUO:
    RAW = RAW / "duo"
W, H = (1398, 2034) if DUO else (1242, 2688)   # 아이폰 듀오 바깥 화면 / App Store 제출 규격 (6.5")
PREFIX = "duo-" if DUO else ""

# (파일, 레이아웃, 헤드라인, 서브카피) — 파일 이름 순서가 스토어에 보이는 순서
SHOTS = {
    "ko": [
        ("01-share.png",  "hero-bleed",  "사진 앱에서 골라<br>바로 발표 자료로", "여러 장을 공유하면 하나로 정리돼요"),
        ("02-list.png",   "left-text",   "강의 장표를<br>발표별로 한눈에", "찍은 장표가 자동으로 묶여요"),
        ("03-slide.png",  "before-after", "비스듬히 찍어도<br>반듯하게", "모서리를 찾아 자동으로 펴 드려요"),
        ("04-detail.png", "text-bottom", "필기 대신 찍고<br>PDF로 정리", "모은 장표를 복습용 PDF로 내보내요"),
        ("05-search.png", "dark",        "장표 속 글자까지<br>검색", "기억나는 단어 하나면 충분해요"),
        ("06-memo.png",   "duo",         "장표마다<br>한 줄 메모", "메모한 단어로도 다시 찾아요"),
    ],
    "en": [
        ("01-share.png",  "hero-bleed",  "From Photos<br>to a deck", "Share several photos, get one tidy deck"),
        ("02-list.png",   "left-text",   "Every lecture,<br>neatly filed", "Slides are grouped by session"),
        ("03-slide.png",  "before-after", "Shot at an angle?<br>Straightened.", "Edges found and corrected for you"),
        ("04-detail.png", "text-bottom", "Snap instead<br>of scribbling", "Export your slides as a study PDF"),
        ("05-search.png", "dark",        "Search the words<br>on your slides", "One word is all it takes"),
        ("06-memo.png",   "duo",         "A quick note<br>on every slide", "Find slides by what you noted"),
    ],
}

# 그 밖의 언어: locales/<로케일>.json 의 shots (레이아웃·파일은 위 순서와 같다)
import json
for _f in sorted((pathlib.Path(__file__).parent / "locales").glob("*.json")):
    _shots = json.loads(_f.read_text(encoding="utf-8"))["shots"]
    SHOTS.setdefault(_f.stem, [(f, l, h, sub) for (f, l, _, _), (h, sub) in zip(SHOTS["en"], _shots)])

# 글자 인식(Vision)이 그 언어를 못 읽어 검색 화면을 보여 줄 수 없는 언어 — 검색 장은 뺀다.
NO_SEARCH = {"el"}

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
    # 7) 아이폰 두 대: 왼쪽(뒤) 원본 파일, 오른쪽(앞·조금 아래) 짝 파일(<이름>-search.png)
    "duo": """
.headline { text-align:center; margin-top:290px; padding:0 70px; }
.sub { text-align:center; margin-top:52px; }
.duo { position:absolute; width:620px; }
.duo.back { left:36px; top:930px; transform:rotate(-4deg); }
.duo.front { left:586px; top:1080px; transform:rotate(3deg); }
.duo .phone { border-radius:74px; padding:16px; }
.duo .phone img { border-radius:58px; }
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

# 아이폰 듀오(바깥 화면)는 아이폰보다 넓고 낮다 — 글은 위로 당기고, 기기는 넓게 아래로 걸친다.
# 장마다 배치를 다르게 두는 것은 아이폰과 같다.
DUO_LAYOUTS = {
    "hero-bleed": """
.headline { text-align:center; margin-top:170px; padding:0 80px; }
.sub { text-align:center; margin-top:44px; }
.wrap { display:flex; justify-content:center; margin-top:110px; }
.phone { width:1080px; }
""",
    "left-text": """
.headline { text-align:left; margin:170px 0 0 110px; }
.sub { text-align:left; margin:44px 0 0 114px; }
.wrap { perspective:2600px; perspective-origin:30% 30%; position:absolute; left:330px; top:700px; }
.phone { width:1000px; transform:rotateY(16deg) rotateX(2deg); }
""",
    "text-bottom": """
.wrap { perspective:2800px; perspective-origin:50% 40%; display:flex; justify-content:center; margin-top:-300px; }
.phone { width:1040px; transform:rotateY(-10deg) rotateX(2deg); }
.headline { text-align:center; margin-top:90px; padding:0 80px; }
.sub { text-align:center; margin-top:40px; }
""",
    "before-after": """
.headline { text-align:center; margin-top:170px; padding:0 80px; }
.sub { text-align:center; margin-top:44px; }
.wrap { display:flex; justify-content:center; margin-top:110px; }
.phone { width:1040px; }
.before { position:absolute; left:60px; top:800px; width:700px; transform:rotate(-7deg);
  background:#fff; padding:18px; border-radius:22px; box-shadow:30px 50px 90px rgba(0,0,0,.35); }
.before img { width:100%; display:block; border-radius:10px; }
""",
    "duo": """
.headline { text-align:center; margin-top:170px; padding:0 80px; }
.sub { text-align:center; margin-top:44px; }
.duo { position:absolute; width:660px; }
.duo.back { left:40px; top:690px; transform:rotate(-4deg); }
.duo.front { left:650px; top:800px; transform:rotate(3deg); }
.duo .phone { border-radius:64px; padding:16px; }
.duo .phone img { border-radius:46px; }
""",
    "dark": """
body { background:#131316; }
.headline { color:#f5f5f7; text-align:center; margin-top:170px; padding:0 80px; }
.sub { color:#77777d; text-align:center; margin-top:44px; }
.wrap { display:flex; justify-content:center; margin-top:110px; }
.phone { width:1040px; border-color:#48484e;
  box-shadow: 0 0 160px rgba(80,140,255,.22), 40px 70px 110px rgba(0,0,0,.55); }
""",
}
# 듀오 바깥 화면은 모서리가 덜 둥글다.
DUO_CSS = ".phone { border-radius:80px; padding:22px; } .phone img { border-radius:58px; }"
if DUO:
    LAYOUTS = {k: DUO_CSS + v for k, v in DUO_LAYOUTS.items()}

# text-bottom 은 폰이 먼저 오는 DOM 순서
BODY_TEXT_FIRST = '<div class="headline">{headline}</div><div class="sub">{sub}</div><div class="wrap"><div class="phone"><img src="{img}"></div></div>'
BODY_PHONE_FIRST = '<div class="wrap"><div class="phone"><img src="{img}"></div></div><div class="headline">{headline}</div><div class="sub">{sub}</div>'

# 긴 언어(독일어·핀란드어 등)는 줄이 화면을 넘지 않을 때까지 헤드라인·서브카피를 줄인다.
FIT = """<script>
for (const [sel, min] of [['.headline', 56], ['.sub', 30]]) {
  const el = document.querySelector(sel);
  el.style.whiteSpace = 'nowrap';
  let size = parseFloat(getComputedStyle(el).fontSize);
  while (el.scrollWidth > el.clientWidth && size > min) { size -= 2; el.style.fontSize = size + 'px'; }
  if (el.scrollWidth > el.clientWidth) document.body.dataset.overflow = '1';
}
</script>"""

HTML = """<!doctype html><html lang="{lang}"><head><meta charset="utf-8"><style>
{base}{layout}
:lang(th) .headline {{ line-height:1.4; }}
:lang(ja) body {{ font-family:"Hiragino Sans", -apple-system, sans-serif; }}
:lang(zh-Hans) body {{ font-family:"PingFang SC", -apple-system, sans-serif; }}
:lang(zh-Hant) body {{ font-family:"PingFang TC", -apple-system, sans-serif; }}
</style></head><body>{body}{fit}</body></html>"""

def render(html_path, out_png):
    # Chrome 은 그림을 저장하고도 종료 감시에 걸려 0이 아닌 코드로 끝나거나 한참 걸린다 — 끝 코드 대신 파일로 판단한다.
    # 나란히 돌리므로 Chrome 마다 따로 프로필을 쓴다(같은 프로필을 쓰면 서로 잠가 멈춘다).
    # 컴퓨터가 바쁘면 아무것도 안 그리고 끝날 때가 있어 세 번까지 한다.
    for attempt in range(3):
        out_png.unlink(missing_ok=True)
        try:
            subprocess.run([CHROME, "--headless=new", f"--user-data-dir={html_path.with_suffix(f'.profile{attempt}')}",
                            f"--screenshot={out_png}",
                            f"--window-size={W},{H}", "--force-device-scale-factor=1",
                            "--hide-scrollbars", "--disable-gpu", "--virtual-time-budget=2000",
                            "--allow-file-access-from-files", html_path.as_uri()],
                           capture_output=True, timeout=180)
        except subprocess.TimeoutExpired:
            pass
        if out_png.exists():
            break
    if not out_png.exists():
        raise SystemExit(f"Chrome 이 그리지 못했다: {out_png}")
    print(f"rendered {out_png.relative_to(ROOT)}")


def main(langs):
    WORK.mkdir(exist_ok=True)
    jobs = []
    for lang in langs:
        out_dir = OUT / lang
        out_dir.mkdir(parents=True, exist_ok=True)
        for fname, layout, headline, sub in SHOTS[lang]:
            if lang in NO_SEARCH and fname.endswith("search.png"):
                (out_dir / (PREFIX + fname)).unlink(missing_ok=True)
                continue
            body_tpl = BODY_PHONE_FIRST if layout == "text-bottom" else BODY_TEXT_FIRST
            raw = RAW / lang / fname
            if layout == "duo":
                pair = RAW / lang / fname.replace(".png", "-search.png")
                body = (f'<div class="headline">{headline}</div><div class="sub">{sub}</div>'
                        f'<div class="duo back"><div class="phone"><img src="{raw.as_uri()}"></div></div>'
                        f'<div class="duo front"><div class="phone"><img src="{pair.as_uri()}"></div></div>')
            else:
                body = body_tpl.format(headline=headline, sub=sub, img=raw.as_uri())
            if layout == "before-after":
                body += f'<div class="before"><img src="{(RAW / lang / "before.jpg").as_uri()}"></div>'
            html_path = WORK / f"{lang}-{PREFIX}{fname.replace('.png', '.html')}"
            html_path.write_text(HTML.format(lang=lang, base=BASE_CSS, layout=LAYOUTS[layout], body=body, fit=FIT), encoding="utf-8")
            jobs.append((html_path, out_dir / (PREFIX + fname)))
    from concurrent.futures import ThreadPoolExecutor
    with ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(lambda job: render(*job), jobs))

if __name__ == "__main__":
    main(sys.argv[1:] or list(SHOTS))
