#!/usr/bin/env python3
"""
App Store Connect 인앱 상품을 레포의 원본에 맞춘다. 기본은 미리 보기, --apply 로 올린다.

    python3 scripts/asc_iap.py            # 무엇이 바뀌는지 보기
    python3 scripts/asc_iap.py --apply    # 올리기
    python3 scripts/asc_iap.py --check    # 표만 검사 (이름 30자 · 설명 55자)

맞추는 것
  1. 선물 상품(소모성)이 없으면 만든다 — 값은 그 칸 평생과 같게, 판매 지역은 전부.
  2. 이름 · 설명 — scripts/asc_iap.json 의 표를 모든 언어로 (구독 묶음 이름 포함).
  3. 심사 메모 — 아래 REVIEW_NOTES.
  4. 연 구독 첫 해 할인 — 첫 1년을 반값에, 처음에 한 번 내는 방식(PAY_UP_FRONT), 구독을 파는 모든 지역.
"""

import json
import os
import sys

from asc import APP_ID, all_pages, call

HERE = os.path.dirname(os.path.abspath(__file__))
NAME_MAX, DESC_MAX = 30, 55

# 선물 = 소모성. 사는 사람은 아무것도 열리지 않고, 앱이 App Store 오퍼 코드 한 장을 꺼내 보낼 링크로 준다.
GIFTS = {"com.leeo.slidesnap.gift.pro": "com.leeo.slidesnap.pro",
         "com.leeo.slidesnap.gift.plus": "com.leeo.slidesnap.plus"}

# 연 구독 첫 해 (미국 기준 값, 다른 지역은 애플의 같은 값 환산)
FIRST_YEAR = {"com.leeo.slidesnap.plus.yearly": "3.99",
              "com.leeo.slidesnap.pro.yearly": "5.99"}

PLACE = "Presentation list > top-left menu > Settings > Plans & Support"
REVIEW_NOTES = {
    "subscription": f"Auto-renewable subscription. Find it in the paywall that opens when creating an 11th presentation, or in {PLACE} > Plans.",
    "lifetime": f"One-time purchase that unlocks this tier for life. Find it in the paywall (Lifetime option) or in {PLACE} > Plans.",
    "com.leeo.slidesnap.pro.upgrade": f"Shown only to people who own Plus Lifetime: upgrades them to Pro Lifetime for the difference. {PLACE} > Plans.",
    "com.leeo.slidesnap.pro.graduate": f"Shown only to active subscribers: switches them to Pro Lifetime at a lower price. {PLACE} > Plans.",
    "tip": f"Optional tip that unlocks nothing. {PLACE} > the tip row.",
    "gift": ("Consumable gift purchase. The buyer does not get anything unlocked themselves. After the purchase the app takes "
             "one App Store offer code (a free one-time offer code for the non-consumable {grants}, created in App Store Connect) "
             "and shows an App Store redeem link for the buyer to send. The recipient taps the link and redeems it in the App Store, "
             "which unlocks the tier. The app never unlocks anything with its own codes. Location: " + PLACE + " > Send a Gift."),
}


def review_note(pid, is_sub):
    if pid in GIFTS:
        return REVIEW_NOTES["gift"].format(grants=GIFTS[pid])
    if is_sub:
        return REVIEW_NOTES["subscription"]
    if ".tip." in pid:
        return REVIEW_NOTES["tip"]
    return REVIEW_NOTES.get(pid, REVIEW_NOTES["lifetime"])


# MARK: - 표

def load_table():
    t = json.load(open(os.path.join(HERE, "asc_iap.json"), encoding="utf-8"))
    rows, errors = {}, []
    for pid, spec in t["products"].items():
        rows[pid] = {}
        for locale, lang in t["locales"].items():
            f = dict(zip(t["fields"], t["languages"][lang]))
            brand = t["brand"].get(lang, t["brand"]["*"])
            fill = lambda s: s.format(brand=brand, tier=spec.get("tier", ""))
            f = {k: fill(v) for k, v in f.items()}
            name = spec["name"].format(**f)
            desc = f[spec["description"]]
            if len(name) > NAME_MAX:
                errors.append(f"{pid} {locale} 이름 {len(name)}자: {name}")
            if len(desc) > DESC_MAX:
                errors.append(f"{pid} {locale} 설명 {len(desc)}자: {desc}")
            rows[pid][locale] = {"name": name, "description": desc}
    subs = {pid for pid, s in t["products"].items() if s.get("subscription")}
    brands = {loc: t["brand"].get(lang, t["brand"]["*"]) for loc, lang in t["locales"].items()}
    return rows, subs, brands, errors


# MARK: - 맞추기

def sync_localizations(kind, owner, wanted, apply, label):
    list_path, res, rel, rel_type = {
        "iap": (f"/v2/inAppPurchases/{owner}/inAppPurchaseLocalizations?limit=200",
                "inAppPurchaseLocalizations", "inAppPurchaseV2", "inAppPurchases"),
        "sub": (f"/v1/subscriptions/{owner}/subscriptionLocalizations?limit=200",
                "subscriptionLocalizations", "subscription", "subscriptions"),
        "group": (f"/v1/subscriptionGroups/{owner}/subscriptionGroupLocalizations?limit=200",
                  "subscriptionGroupLocalizations", "subscriptionGroup", "subscriptionGroups"),
    }[kind]
    have = {x["attributes"]["locale"]: x for x in all_pages(list_path)}
    n = 0
    for locale, attrs in wanted.items():
        cur = have.get(locale)
        if cur and all(cur["attributes"].get(k) == v for k, v in attrs.items()):
            continue
        n += 1
        print(f"  {'고침' if cur else '새로'} {label} {locale}: {attrs['name']}")
        if not apply:
            continue
        if cur:
            call("PATCH", f"/v1/{res}/{cur['id']}", {"data": {"type": res, "id": cur["id"], "attributes": attrs}})
        else:
            call("POST", f"/v1/{res}", {"data": {"type": res, "attributes": {"locale": locale, **attrs},
                                                 "relationships": {rel: {"data": {"type": rel_type, "id": owner}}}}})
    return n


def sync_review_note(kind, item, note, apply):
    if (item["attributes"].get("reviewNote") or "") == note:
        return 0
    print(f"  심사 메모 {item['attributes']['productId']}")
    if apply:
        res, path = ("inAppPurchases", f"/v2/inAppPurchases/{item['id']}") if kind == "iap" \
            else ("subscriptions", f"/v1/subscriptions/{item['id']}")
        call("PATCH", path, {"data": {"type": res, "id": item["id"], "attributes": {"reviewNote": note}}})
    return 1


def usa_iap_price(iap_id):
    sid = call("GET", f"/v2/inAppPurchases/{iap_id}/iapPriceSchedule")["data"]["id"]
    r = call("GET", f"/v1/inAppPurchasePriceSchedules/{sid}/manualPrices?include=inAppPurchasePricePoint,territory&limit=200")
    pts = {i["id"]: i["attributes"]["customerPrice"] for i in r.get("included", []) if i["type"] == "inAppPurchasePricePoints"}
    for p in r["data"]:
        if p["relationships"]["territory"]["data"]["id"] == "USA":
            return pts[p["relationships"]["inAppPurchasePricePoint"]["data"]["id"]]


def create_gift(pid, grants_id, price, rows):
    print(f"  새 상품 {pid} (소모성, ${price})")
    iap = call("POST", "/v2/inAppPurchases", {"data": {"type": "inAppPurchases", "attributes": {
        "name": rows[pid]["en-US"]["name"], "productId": pid, "inAppPurchaseType": "CONSUMABLE",
        "reviewNote": review_note(pid, False)},
        "relationships": {"app": {"data": {"type": "apps", "id": APP_ID}}}}})["data"]
    point = next(p["id"] for p in all_pages(f"/v2/inAppPurchases/{iap['id']}/pricePoints?filter[territory]=USA&limit=200")
                 if p["attributes"]["customerPrice"] == price)
    call("POST", "/v1/inAppPurchasePriceSchedules", {
        "data": {"type": "inAppPurchasePriceSchedules", "relationships": {
            "inAppPurchase": {"data": {"type": "inAppPurchases", "id": iap["id"]}},
            "baseTerritory": {"data": {"type": "territories", "id": "USA"}},
            "manualPrices": {"data": [{"type": "inAppPurchasePrices", "id": "${p}"}]}}},
        "included": [{"type": "inAppPurchasePrices", "id": "${p}", "attributes": {"startDate": None},
                      "relationships": {"inAppPurchasePricePoint": {"data": {"type": "inAppPurchasePricePoints", "id": point}}}}]})
    territories = [{"type": "territories", "id": t["id"]} for t in all_pages("/v1/territories?limit=200")]
    call("POST", "/v1/inAppPurchaseAvailabilities", {"data": {
        "type": "inAppPurchaseAvailabilities", "attributes": {"availableInNewTerritories": True},
        "relationships": {"inAppPurchase": {"data": {"type": "inAppPurchases", "id": iap["id"]}},
                          "availableTerritories": {"data": territories}}}})
    return iap


def sync_first_year(sub, usa_price, apply):
    have = call("GET", f"/v1/subscriptions/{sub['id']}/introductoryOffers?limit=1")["data"]
    if have:
        return 0
    pid = sub["attributes"]["productId"]
    avail = call("GET", f"/v1/subscriptions/{sub['id']}/subscriptionAvailability")["data"]["id"]
    sold = {t["id"] for t in all_pages(f"/v1/subscriptionAvailabilities/{avail}/availableTerritories?limit=200")}
    print(f"  첫 해 할인 {pid}: ${usa_price} · {len(sold)}개 지역")
    if not apply:
        return 1
    usa = next(p for p in all_pages(f"/v1/subscriptions/{sub['id']}/pricePoints?filter[territory]=USA&limit=200")
               if p["attributes"]["customerPrice"] == usa_price)
    points = {"USA": usa["id"]}
    for p in all_pages(f"/v1/subscriptionPricePoints/{usa['id']}/equalizations?include=territory&limit=200"):
        points[p["relationships"]["territory"]["data"]["id"]] = p["id"]
    for t in sorted(sold):
        if t not in points:
            print(f"    ⚠️ {t}: 같은 값 환산이 없어 건너뜀")
            continue
        call("POST", "/v1/subscriptionIntroductoryOffers", {"data": {
            "type": "subscriptionIntroductoryOffers",
            "attributes": {"duration": "ONE_YEAR", "offerMode": "PAY_UP_FRONT", "numberOfPeriods": 1, "startDate": None},
            "relationships": {"subscription": {"data": {"type": "subscriptions", "id": sub["id"]}},
                              "territory": {"data": {"type": "territories", "id": t}},
                              "subscriptionPricePoint": {"data": {"type": "subscriptionPricePoints", "id": points[t]}}}}})
    return 1


def main():
    apply = "--apply" in sys.argv
    rows, subs, brands, errors = load_table()
    if errors:
        sys.exit("❌ 표가 길이 제한을 넘는다\n" + "\n".join(errors))
    print(f"✅ 표 검사 통과: 상품 {len(rows)}개 · 언어 {len(next(iter(rows.values())))}개")
    if "--check" in sys.argv:
        return

    n = 0
    iaps = {x["attributes"]["productId"]: x for x in all_pages(f"/v1/apps/{APP_ID}/inAppPurchasesV2?limit=200")}
    for gift, grants in GIFTS.items():
        if gift not in iaps:
            n += 1
            price = usa_iap_price(iaps[grants]["id"])
            if apply:
                iaps[gift] = create_gift(gift, grants, price, rows)
            else:
                print(f"  새 상품 {gift} (소모성, 값은 {grants} 와 같은 ${price})")

    for pid, item in iaps.items():
        if pid in rows:
            n += sync_localizations("iap", item["id"], rows[pid], apply, pid)
            n += sync_review_note("iap", item, review_note(pid, False), apply)

    for g in all_pages(f"/v1/apps/{APP_ID}/subscriptionGroups?limit=50"):
        n += sync_localizations("group", g["id"], {loc: {"name": b} for loc, b in brands.items()}, apply, "구독 묶음")
        for s in all_pages(f"/v1/subscriptionGroups/{g['id']}/subscriptions?limit=50"):
            pid = s["attributes"]["productId"]
            if pid in rows:
                n += sync_localizations("sub", s["id"], rows[pid], apply, pid)
                n += sync_review_note("sub", s, review_note(pid, True), apply)
            if pid in FIRST_YEAR:
                n += sync_first_year(s, FIRST_YEAR[pid], apply)

    missing = set(rows) - set(iaps) - subs
    for pid in sorted(missing):
        print(f"⚠️ App Store Connect 에 없는 상품: {pid}")
    print(f"{'✅ 올림' if apply else '📝 바뀔 것 (--apply 로 올린다)'}: {n}건")


if __name__ == "__main__":
    main()
