"""
App Store Connect API 를 부르는 가장 작은 손잡이. go_free.py · asc_iap.py 가 같이 쓴다.

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
API = "https://api.appstoreconnect.apple.com"


def _b64url(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def _der_to_raw(der):
    # ECDSA DER (SEQUENCE { INTEGER r, INTEGER s }) -> r||s 64바이트
    i = 2 if der[1] < 0x80 else 3
    parts = []
    for _ in range(2):
        n = der[i + 1]
        parts.append(der[i + 2:i + 2 + n][-32:].rjust(32, b"\0"))
        i += 2 + n
    return b"".join(parts)


def _token():
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
    signing = f"{_b64url(json.dumps(head).encode())}.{_b64url(json.dumps(body).encode())}"
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path],
                         input=signing.encode(), capture_output=True, check=True).stdout
    return f"{signing}.{_b64url(_der_to_raw(der))}"


_TOKEN = None


def call(method, path, body=None):
    global _TOKEN
    _TOKEN = _TOKEN or _token()
    url = path if path.startswith("http") else API + path
    req = urllib.request.Request(url, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": f"Bearer {_TOKEN}",
                                          "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        sys.exit(f"❌ {method} {path}: {e.code} {e.read().decode()[:800]}")


def all_pages(path):
    items, url = [], path
    while url:
        page = call("GET", url)
        items += page.get("data", [])
        url = page.get("links", {}).get("next")
    return items
