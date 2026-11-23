#!/bin/zsh
# Mac(Catalyst) 앱스토어 스크린샷 — 이 Mac 에서 DEBUG 앱을 데모 모드로 띄워 창을 찍는다.
#
#   scripts/screenshots/make_mac_screenshots.sh [언어 ...]      (없으면 24개 언어 전부)
#   → docs/screenshots/raw/mac/<언어>/NN-….png (창 그대로) → docs/screenshots/marketing/<언어>/mac-NN-….png (2880×1800)
#
# 장면은 iPad · Vision Pro 와 같다: 목록 · 공부하기 · 장표 · 검색. 데모 발표는 iOS 와 같은 길로 만든다 —
# 데모 사진을 앱 그룹 수신함에 넣으면 앱이 실제 보정 · 글자 인식으로 발표를 만든다(make_demo_photos.py).
# 창은 데모 모드에서 1440×900 으로 묶인다(PresentationListView.showDemo).
#
# ⚠️ 이 Mac 의 장표스냅 컨테이너를 쓰고, 끝나면(중간에 실패해도) 지운다. 진짜 장표스냅이 떠 있으면 시작하지 않는다.
# 화면 기록 권한이 있는 터미널에서 돌릴 것. 창이 화면에 잠깐씩 뜨고 닫힌다.
set -euo pipefail
cd "${0:A:h}/../.."
ROOT=$PWD
ALL=(ko en en-GB zh-Hans zh-Hant ja ru es de fr it pt-BR th vi cs da el fi id nb nl pl sv tr)
LANGS=(${@:-$ALL})
DERIVED=$ROOT/build/mac-shots
APP=$DERIVED/Build/Products/Debug-maccatalyst/CatchSlide.app
BIN=$APP/Contents/MacOS/CatchSlide
# 앱 컨테이너는 macOS 가 UUID 이름으로 만들기도 한다 — 번들 ID 로 찾아 지운다.
wipe() {
  local d
  for d in $HOME/Library/Containers/*(N/); do
    [[ $(plutil -extract MCMMetadataIdentifier raw "$d/.com.apple.containermanagerd.metadata.plist" 2>/dev/null) == com.leeo.slidesnap ]] && rm -rf "$d"
  done
  rm -rf "$GROUP"
}
GROUP="$HOME/Library/Group Containers/group.com.leeo.slidesnap"
# 앱이 저장한 장표 수
slide_count() {
  local d
  for d in $HOME/Library/Containers/*(N/); do
    [[ $(plutil -extract MCMMetadataIdentifier raw "$d/.com.apple.containermanagerd.metadata.plist" 2>/dev/null) == com.leeo.slidesnap ]] || continue
    python3 -c "import json,sys; print(sum(len(p.get('slides',[])) for p in json.load(open(sys.argv[1]))))" "$d/Data/Documents/store.json" 2>/dev/null && return
  done
  echo 0
}
RAW=docs/screenshots/raw/mac
WORK=$(mktemp -d)

if pgrep -f "/Applications/.*(SlideSnap|CatchSlide).app/Contents/MacOS" >/dev/null; then
  echo "❌ 진짜 장표스냅 Mac 앱이 떠 있다 — 끄고 다시 돌릴 것"; exit 1
fi

locale_for() {
  case $1 in
    ko) echo ko_KR;; en) echo en_US;; en-GB) echo en_GB;; zh-Hans) echo zh_CN;; zh-Hant) echo zh_TW;;
    ja) echo ja_JP;; ru) echo ru_RU;; es) echo es_ES;; de) echo de_DE;; fr) echo fr_FR;; it) echo it_IT;;
    pt-BR) echo pt_BR;; th) echo th_TH;; vi) echo vi_VN;; cs) echo cs_CZ;; da) echo da_DK;; el) echo el_GR;;
    fi) echo fi_FI;; id) echo id_ID;; nb) echo nb_NO;; nl) echo nl_NL;; pl) echo pl_PL;; sv) echo sv_SE;; tr) echo tr_TR;;
    *) echo en_US;;
  esac
}

cleanup() {
  pkill -f "$BIN" 2>/dev/null || true
  sleep 1
  wipe
  echo "↩︎  이 Mac 의 장표스냅 데모 데이터를 지웠다"
}
trap cleanup EXIT

echo "빌드 중…"
xcodebuild -project SlideSnap.xcodeproj -scheme SlideSnap -configuration Debug \
  -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates build -quiet 2>&1 | grep -v "ld: warning" || true
[[ -x $BIN ]] || { echo "❌ 빌드 실패"; exit 1; }

# 창 번호 찾기 — 그 프로세스의 화면 위 첫 일반 창
cat > $WORK/winid.swift <<'SWIFT'
import CoreGraphics
let pid = Int32(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
if let w = list.first(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }) {
    print(w[kCGWindowNumber as String]!)
}
SWIFT
swiftc -O $WORK/winid.swift -o $WORK/winid

launch() {  # launch <lang> [데모 인자...]
  local lang=$1; shift
  pkill -f "$BIN" 2>/dev/null || true; sleep 1
  open -n "$APP" --args -AppleLanguages "($lang)" -AppleLocale $(locale_for $lang) "$@"
}

shoot() {  # shoot <lang> <파일이름> <데모 화면> — 창이 늦게 뜨는 때가 있어 세 번까지 다시 띄운다
  local try
  for try in 1 2 3; do shoot_once "$@" && return 0; echo "  ↻ 다시 ($try)"; done
  return 1
}

shoot_once() {
  local lang=$1 name=$2 screen=$3 pid wid
  launch $lang -SSDemoScreen "$screen" "${MEMO_ARGS[@]}"
  sleep 6
  pid=$(pgrep -f "$BIN" | head -1 || true)
  [[ -z $pid ]] && { echo "  ❌ 앱이 뜨지 않음 ($screen)"; return 1; }
  wid=$($WORK/winid $pid || true)
  [[ -z $wid ]] && { echo "  ❌ 창을 못 찾음 ($screen)"; return 1; }
  rm -f $RAW/$lang/$name
  screencapture -x -o -l $wid $RAW/$lang/$name 2>/dev/null; [[ -s $RAW/$lang/$name ]] || { echo "  ❌ 창을 못 찍음 ($screen)"; return 1; }
  echo "  찍음 $lang/$name"
}

for lang in $LANGS; do
  echo "── $lang"
  python3 scripts/screenshots/make_demo_photos.py $lang "$WORK/demo-$lang" >/dev/null
  pkill -f "$BIN" 2>/dev/null || true; sleep 1
  wipe
  mkdir -p "$GROUP"
  cp -R "$WORK/demo-$lang/ShareInbox" "$GROUP/"
  # 사진이 모두 장표가 될 때까지 기다린다 — 수신함이 비었다고 끝난 게 아니다(앱이 늦게 뜨면 아예 안 가져가기도 한다).
  want=$(python3 -c "import json,glob,sys; print(sum(len(json.load(open(m))['files']) for m in glob.glob(sys.argv[1]+'/ShareInbox/*/manifest.json')))" "$WORK/demo-$lang")
  got=0
  for attempt in 1 2 3; do
    launch $lang
    for i in {1..90}; do
      sleep 2
      got=$(slide_count)
      [[ $got == $want && -z "$(ls "$GROUP/ShareInbox" 2>/dev/null)" ]] && break 2
    done
    echo "  ↻ 발표 만들기 다시 ($got/$want)"
  done
  [[ $got == $want ]] || { echo "  ❌ 발표를 다 만들지 못함 ($got/$want)"; exit 1; }
  sleep 5   # 글자 인식 마무리
  echo "  발표 생성 완료 (${got}장)"

  mkdir -p $RAW/$lang
  query=$(python3 -c "import sys; sys.path.insert(0, 'scripts/screenshots'); from slides import SEARCH; print(SEARCH['$lang'])")
  MEMO_ARGS=("${(@f)$(python3 -c "
import sys; sys.path.insert(0, 'scripts/screenshots'); from slides import MEMOS
for i, m in MEMOS['$lang'].items(): print(f'-SSDemoMemo{i}'); print(m)")}")
  shoot $lang 04-list.png  list
  shoot $lang 08-study.png study
  shoot $lang 05-slide.png slide
  [[ $lang == el ]] || shoot $lang 07-search.png "search:$query"   # 그리스어는 글자 인식이 못 읽는다

  OUT=docs/screenshots/marketing/$lang; mkdir -p $OUT; rm -f $OUT/mac-*.png(N)
  n=0
  for f in 04-list 08-study 05-slide 07-search; do
    [[ -f $RAW/$lang/$f.png ]] || continue
    n=$((n+1))
    # Chrome 이 가끔 그리지 못한다 — 세 번까지
    for try in 1 2 3; do python3 scripts/screenshots/frame_mac.py $RAW/$lang/$f.png $OUT/mac-0$n-${f#*-}.png && break; sleep 2; done
  done
done
