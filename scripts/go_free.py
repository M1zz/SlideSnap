#!/usr/bin/env python3
"""
출시하는 날 한 번: 앱 가격을 무료로 내리고, 심사를 통과해 기다리는 버전을 내보낸다.

장표스냅은 1.0.10 까지 유료 다운로드였고, 1.0.11 부터 무료 + Plus · Pro 다.
둘은 같은 날 바뀌어야 한다.
  가격만 먼저 내리면 → 모든 기능이 열린 1.0.10 을 누구나 공짜로 받는다.
  버전만 먼저 나가면 → 돈 내고 받은 새 빌드(12 이상)가 기존 구매자로 인정되지 않아 페이월에 막힌다.
그래서 deploy.env 는 AUTO_RELEASE=off 이고, 심사를 통과하면 이 스크립트로 둘을 함께 한다.

    python3 scripts/go_free.py           # 지금 상태만 보기
    python3 scripts/go_free.py --apply   # 무료로 내리고 출시

키: ~/Documents/workspace/fastlane-shared/asc.env 의 ASC_KEY_ID · ASC_ISSUER_ID (DeployBar 와 같다).
외부 패키지 없이 돈다(서명은 openssl).
"""

import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

APP_ID = "6790835318"
VERSION = "1.0.11"
API = "https://api.appstoreconnect.apple.com"
DEPLOYBAR = "/Applications/DeployBar.app/Contents/MacOS/DeployBar"


def b64url(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def der_to_raw(der):
    i = 2 if der[1] < 0x80 else 3
    parts = []
    for _ in range(2):
        n = der[i + 1]
        parts.append(der[i + 2:i + 2 + n][-32:].rjust(32, b"\0"))
        i += 2 + n
    return b"".join(parts)


def token():
    env = {}
    for line in open(os.path.expanduser("~/Documents/workspace/fastlane-shared/asc.env")):
        line = line.strip().removeprefix("export ")
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            env[k.strip()] = os.path.expanduser(v.strip().strip("\"'"))
    key_path = env.get("ASC_KEY_PATH") or os.path.expanduser(
        f"~/.appstoreconnect/private_keys/AuthKey_{env['ASC_KEY_ID']}.p8")
    now = int(time.time())
    head = {"alg": "ES256", "kid": env["ASC_KEY_ID"], "typ": "JWT"}
    body = {"iss": env["ASC_ISSUER_ID"], "iat": now, "exp": now + 1100, "aud": "appstoreconnect-v1"}
    signing = f"{b64url(json.dumps(head).encode())}.{b64url(json.dumps(body).encode())}"
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path],
                         input=signing.encode(), capture_output=True, check=True).stdout
    return f"{signing}.{b64url(der_to_raw(der))}"


TOKEN = token()


def call(method, path, body=None):
    req = urllib.request.Request(API + path, method=method,
                                 data=json.dumps(body).encode() if body else None,
                                 headers={"Authorization": f"Bearer {TOKEN}",
                                          "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        sys.exit(f"❌ {method} {path}: {e.code} {e.read().decode()[:600]}")


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
