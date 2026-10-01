#!/bin/zsh
# 앱스토어 원본 스크린샷 찍기 (시뮬레이터 · DEBUG 데모 모드).
#
#   scripts/screenshots/make_screenshots.sh [ko|en ...]    (기본: ko en)
#
# 1) 데모 사진 합성 → 2) 앱을 새로 깔고 App Group 수신함에 넣어 실제 보정 파이프라인으로 발표 생성
# 3) -SSDemoScreen 인자로 화면을 하나씩 띄워 docs/screenshots/raw/<언어>/ 에 저장
# 이어서 make_marketing.py 가 제출본(docs/screenshots/marketing/<언어>/)을 만든다.
set -euo pipefail
cd "${0:A:h}/../.."
ROOT=$PWD
LANGS=(${@:-ko en})
DEVICE_NAME="${DEVICE_NAME:-iPhone 17 Pro Max}"   # 다른 작업과 시뮬레이터가 겹치면 DEVICE_NAME 으로 바꿔 찍는다
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
xcrun simctl status_bar $UDID override --time 9:41 --dataNetwork wifi --wifiBars 3 --cellularBars 4 --batteryState charged --batteryLevel 100

echo "빌드 중…"
xcodebuild -project SlideSnap.xcodeproj -scheme SlideSnap -configuration Debug \
  -destination "id=$UDID" -derivedDataPath "$WORK/dd" build -quiet
APP="$WORK/dd/Build/Products/Debug-iphonesimulator/SlideSnap.app"

shoot() {  # shoot <lang> <파일이름> <데모 화면> <대기 초>
  local lang=$1 name=$2 screen=$3 wait=$4 locale
  [[ $lang == ko ]] && locale=ko_KR || locale=en_US
  xcrun simctl terminate $UDID $BUNDLE 2>/dev/null || true
  xcrun simctl launch $UDID $BUNDLE -AppleLanguages "($lang)" -AppleLocale $locale -SSDemoScreen "$screen" >/dev/null
  sleep $wait
  xcrun simctl io $UDID screenshot "docs/screenshots/raw/$lang/$name" >/dev/null 2>&1
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
  [[ $lang == ko ]] && locale=ko_KR || locale=en_US
  xcrun simctl launch $UDID $BUNDLE -AppleLanguages "($lang)" -AppleLocale $locale >/dev/null
  for i in {1..120}; do [[ -z "$(ls "$G/ShareInbox" 2>/dev/null)" ]] && break; sleep 2; done
  sleep 3
  echo "  발표 생성 완료"

  mkdir -p docs/screenshots/raw/$lang
  # 제출본 3번의 '보정 전' 카드 — 맨 위 발표(UX 리서치)의 둘째 장 원본 사진
  cp "$WORK/demo-$lang/ShareInbox/00000000-0000-0000-0000-000000000004/0002.jpg" docs/screenshots/raw/$lang/before.jpg
  [[ $lang == ko ]] && query="사용자 인터뷰" || query="user interview"
  shoot $lang 01-share.png  share  6
  shoot $lang 02-list.png   list   4
  shoot $lang 03-slide.png  slide  4
  shoot $lang 04-detail.png detail 4
  shoot $lang 05-search.png "search:$query" 4
done
xcrun simctl status_bar $UDID clear
rm -rf "$WORK"
echo "완료 → docs/screenshots/raw/"
