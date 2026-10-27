#!/bin/zsh
# 앱스토어 원본 스크린샷 찍기 (시뮬레이터 · DEBUG 데모 모드).
#
#   scripts/screenshots/make_screenshots.sh [ko|en ...]    (기본: ko en)
#   KIND=duo scripts/screenshots/make_screenshots.sh ...    아이폰 듀오 바깥 화면(1398×2034) → raw/duo/<언어>/
#     듀오는 Xcode 27.1 이상으로 빌드해야 호환 틀(옆 검은 띠) 없이 뜬다. 안쪽 화면은 손으로 펴야 해서 찍지 않는다.
#
# 1) 데모 사진 합성 → 2) 앱을 새로 깔고 App Group 수신함에 넣어 실제 보정 파이프라인으로 발표 생성
# 3) -SSDemoScreen 인자로 화면을 하나씩 띄워 docs/screenshots/raw/<언어>/ 에 저장
# 이어서 make_marketing.py 가 제출본(docs/screenshots/marketing/<언어>/)을 만든다.
set -euo pipefail
cd "${0:A:h}/../.."
ROOT=$PWD
LANGS=(${@:-ko en})
KIND="${KIND:-iphone}"
if [[ $KIND == duo ]]; then
  DEFAULT_DEVICE="iPhone Duo"; RAW=docs/screenshots/raw/duo; DISPLAY_ARGS=(--display=1)   # 1번이 바깥 화면
else
  DEFAULT_DEVICE="iPhone 18 Pro Max"; RAW=docs/screenshots/raw; DISPLAY_ARGS=()
fi
DEVICE_NAME="${DEVICE_NAME:-$DEFAULT_DEVICE}"   # 다른 작업과 시뮬레이터가 겹치면 DEVICE_NAME 으로 바꿔 찍는다
BUNDLE=com.leeo.slidesnap
GROUP=group.com.leeo.slidesnap
WORK=$(mktemp -d)

UDID=$(xcrun simctl list devices available -j | python3 -c "
import json,sys
d=json.load(sys.stdin)['devices']
c=[x for rt,v in d.items() if 'iOS' in rt for x in v if x['name']=='$DEVICE_NAME']
b=[x for x in c if x['state']=='Booted']
print((b or c)[0]['udid'])")
echo "기기: $DEVICE_NAME ($UDID)"
xcrun simctl boot $UDID 2>/dev/null || true
xcrun simctl bootstatus $UDID -b >/dev/null
xcrun simctl ui $UDID appearance light   # 제출본은 라이트 모드로 맞춘다(기기마다 설정이 다를 수 있다)
xcrun simctl status_bar $UDID override --time 9:41 --dataNetwork wifi --wifiBars 3 --cellularBars 4 --batteryState charged --batteryLevel 100

echo "빌드 중…"
xcodebuild -project SlideSnap.xcodeproj -scheme SlideSnap -configuration Debug \
  -destination "id=$UDID" -derivedDataPath "$WORK/dd" build -quiet
APP="$WORK/dd/Build/Products/Debug-iphonesimulator/SlideSnap.app"

# 스토어 로케일 → 기기 지역(날짜·숫자 형식). en-GB 는 영국식 날짜(일/월)로 찍힌다.
locale_for() {
  case $1 in
    ko) echo ko_KR;; en) echo en_US;; en-GB) echo en_GB;; zh-Hans) echo zh_CN;; zh-Hant) echo zh_TW;;
    ja) echo ja_JP;; ru) echo ru_RU;; es) echo es_ES;; de) echo de_DE;; fr) echo fr_FR;; it) echo it_IT;;
    pt-BR) echo pt_BR;; th) echo th_TH;; vi) echo vi_VN;; cs) echo cs_CZ;; da) echo da_DK;; el) echo el_GR;;
    fi) echo fi_FI;; id) echo id_ID;; nb) echo nb_NO;; nl) echo nl_NL;; pl) echo pl_PL;; sv) echo sv_SE;; tr) echo tr_TR;;
    *) echo en_US;;
  esac
}

shoot() {  # shoot <lang> <파일이름> <데모 화면> <대기 초>
  local lang=$1 name=$2 screen=$3 wait=$4 locale
  locale=$(locale_for $lang)
  xcrun simctl terminate $UDID $BUNDLE 2>/dev/null || true
  # 기계가 바쁘면 실행 명령이 돌아오지 않을 때가 있다 — 60초 안에 안 끝나면 끊고 다시 띄운다.
  local n
  for n in 1 2 3; do
    perl -e 'alarm shift; exec @ARGV' 60 xcrun simctl launch $UDID $BUNDLE -AppleLanguages "($lang)" -AppleLocale $locale -SSDemoScreen "$screen" "${MEMO_ARGS[@]}" >/dev/null && break
    xcrun simctl terminate $UDID $BUNDLE 2>/dev/null || true
  done
  sleep $wait
  # Mac 이 바쁘면 앱이 그리기 전에 찍혀 빈 화면이 남는다 — 상태 막대 아래가 거의 한 색이면 기다렸다 다시 찍는다.
  local try
  for try in 1 2 3 4 5 6; do
    # 다른 작업이 시뮬레이터를 같이 쓰면 찍기가 멈출 때가 있다 — 60초 안에 안 끝나면 끊고 다시 찍는다.
    perl -e 'alarm shift; exec @ARGV' 60 xcrun simctl io $UDID screenshot --type=png "${DISPLAY_ARGS[@]}" "$RAW/$lang/$name" >/dev/null 2>&1 || true
    python3 - "$RAW/$lang/$name" <<'PY' && break
import sys
from PIL import Image, ImageStat
im = Image.open(sys.argv[1]).convert("L")
w, h = im.size
body = im.crop((0, int(h * 0.08), int(w * 0.8), int(h * 0.92)))   # 듀오는 오른쪽 세로줄에 시계·버튼이 서서 빈 화면도 얼룩져 보인다 — 빼고 본다
sys.exit(0 if ImageStat.Stat(body).stddev[0] > 12 else 1)
PY
    echo "  빈 화면 — 다시 찍음 ($try)"
    sleep $((wait * 2))
  done
  echo "  찍음 $lang/$name"
}

for lang in $LANGS; do
  echo "── $lang"
  python3 scripts/screenshots/make_demo_photos.py $lang "$WORK/demo-$lang"
  xcrun simctl uninstall $UDID $BUNDLE 2>/dev/null || true
  xcrun simctl install $UDID "$APP"
  xcrun simctl privacy $UDID grant camera $BUNDLE 2>/dev/null || true
  G=$(xcrun simctl get_app_container $UDID $BUNDLE $GROUP)
  rm -rf "$G/ShareInbox" "$G/DemoShare"
  cp -R "$WORK/demo-$lang/ShareInbox" "$WORK/demo-$lang/DemoShare" "$G/"

  # 수신함을 앱이 다 가져갈 때까지(발표로 만들어질 때까지) 기다린다.
  locale=$(locale_for $lang)
  # 설치 직후엔 앱이 아직 등록되지 않아 실행이 거부될 때가 있다 — 잠깐 기다려 다시 띄운다.
  for i in {1..5}; do
    perl -e 'alarm shift; exec @ARGV' 60 xcrun simctl launch $UDID $BUNDLE -AppleLanguages "($lang)" -AppleLocale $locale >/dev/null && break
    sleep 5
  done
  for i in {1..120}; do [[ -z "$(ls "$G/ShareInbox" 2>/dev/null)" ]] && break; sleep 2; done
  sleep 3
  echo "  발표 생성 완료"

  mkdir -p $RAW/$lang
  # 제출본 3번의 '보정 전' 카드 — 맨 위 발표(UX 리서치)의 둘째 장 원본 사진
  cp "$WORK/demo-$lang/ShareInbox/00000000-0000-0000-0000-000000000004/0002.jpg" $RAW/$lang/before.jpg
  query=$(python3 -c "import sys; sys.path.insert(0, 'scripts/screenshots'); from slides import SEARCH; print(SEARCH['$lang'])")
  memo_query=$(python3 -c "import sys; sys.path.insert(0, 'scripts/screenshots'); from slides import MEMO_SEARCH; print(MEMO_SEARCH['$lang'])")
  # 첫 발표의 장표들에 데모 메모를 단다(모든 화면에 같이 넘겨 그리드에도 메모 표시가 보이게).
  MEMO_ARGS=("${(@f)$(python3 -c "
import sys; sys.path.insert(0, 'scripts/screenshots'); from slides import MEMOS
for i, m in MEMOS['$lang'].items(): print(f'-SSDemoMemo{i}'); print(m)")}")
  shoot $lang 01-share.png  share  6
  shoot $lang 02-list.png   list   4
  shoot $lang 03-slide.png  slide  4
  shoot $lang 04-detail.png detail 4
  # 그리스어는 글자 인식(Vision)이 읽지 못해 검색 화면을 찍지 않는다(make_marketing.py NO_SEARCH).
  [[ $lang == el ]] || shoot $lang 05-search.png "search:$query" 4
  # 06 메모 소개(아이폰 두 대): 메모를 단 장표 + 메모 단어로 찾은 결과. 메모 검색은 글자 인식과 상관없어 그리스어도 찍는다.
  shoot $lang 06-memo.png        "slide:3"              4
  shoot $lang 06-memo-search.png "search:$memo_query"   4
done
xcrun simctl status_bar $UDID clear
rm -rf "$WORK"
echo "완료 → $RAW/"
