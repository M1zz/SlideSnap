#!/usr/bin/env python3
"""
출시하는 날 한 번: 앱 가격을 무료로 내리고, 심사를 통과해 기다리는 버전을 내보낸다.

장표스냅은 1.0.10 까지 유료 다운로드였고, 1.0.11 부터 무료 + Plus · Pro 다.
둘은 같은 날 바뀌어야 한다.
  가격만 먼저 내리면 → 모든 기능이 열린 1.0.10 을 누구나 공짜로 받는다.
  버전만 먼저 나가면 → 돈 내고 받은 새 빌드(12 이상)가 기존 구매자로 인정되지 않아 페이월에 막힌다.
그래서 deploy.env 는 AUTO_RELEASE=off 이고, 심사를 통과하면 이 스크립트로 둘을 함께 한다.

⚠️ 이 스크립트 전에 선물 묶음을 채운다. 오퍼 코드는 심사를 통과한 상품에만 만들 수 있어서
   1.0.11 이 통과해야 비로소 채워진다. 묶음이 비면 선물을 산 사람이 "준비 중" 에서 기다린다.
   FeedbackHubViewer(Debug-Production) 를 -autoFillGiftPool "com.leeo.slidesnap,com.leeo.slidesnap#com.leeo.slidesnap.plus" 로.

    python3 scripts/go_free.py           # 지금 상태만 보기
    python3 scripts/go_free.py --apply   # 무료로 내리고 출시

키와 API 호출은 scripts/asc.py.
"""

import subprocess
import sys

from asc import API, APP_ID, call

VERSION = "1.0.11"
DEPLOYBAR = "/Applications/DeployBar.app/Contents/MacOS/DeployBar"


def current_price():
    sid = call("GET", f"/v1/apps/{APP_ID}/appPriceSchedule")["data"]["id"]
    s = call("GET", f"/v1/appPriceSchedules/{sid}/manualPrices?include=appPricePoint&limit=50")
    pts = {p["id"]: p["attributes"]["customerPrice"] for p in s.get("included", [])}
    for p in s["data"]:
        if p["attributes"].get("endDate") is None:
            return pts.get(p["relationships"]["appPricePoint"]["data"]["id"])
    return None


def free_point():
    path = f"/v1/apps/{APP_ID}/appPricePoints?filter[territory]=USA&limit=200"
    while path:
        page = call("GET", path)
        for p in page["data"]:
            if float(p["attributes"]["customerPrice"]) == 0:
                return p["id"]
        nxt = page.get("links", {}).get("next")
        path = nxt.removeprefix(API) if nxt else None
    sys.exit("❌ 무료 가격 포인트를 못 찾았습니다")


def version_state():
    vs = call("GET", f"/v1/apps/{APP_ID}/appStoreVersions?filter[versionString]={VERSION}&filter[platform]=IOS")
    return vs["data"][0]["attributes"]["appStoreState"] if vs["data"] else None


def make_free():
    call("POST", "/v1/appPriceSchedules", {
        "data": {"type": "appPriceSchedules", "relationships": {
            "app": {"data": {"type": "apps", "id": APP_ID}},
            "baseTerritory": {"data": {"type": "territories", "id": "USA"}},
            "manualPrices": {"data": [{"type": "appPrices", "id": "${free}"}]}}},
        "included": [{"type": "appPrices", "id": "${free}", "attributes": {"startDate": None},
                      "relationships": {"appPricePoint": {"data": {"type": "appPricePoints",
                                                                   "id": free_point()}}}}]})


price, state = current_price(), version_state()
print(f"가격(미국 기준): ${price}  ·  v{VERSION}: {state}")
if "--apply" not in sys.argv:
    sys.exit(0)
if state != "PENDING_DEVELOPER_RELEASE":
    sys.exit(f"⏸ v{VERSION} 이 아직 '출시 대기' 가 아닙니다({state}). 심사를 통과한 뒤 다시 실행하세요. 가격은 그대로 둡니다.")
if price is None or float(price) > 0:
    make_free()
    print(f"✅ 가격을 무료로 내렸습니다 (전: ${price})")
else:
    print("✅ 이미 무료입니다")
sys.exit(subprocess.run([DEPLOYBAR, "--release", "장표스냅"]).returncode)
