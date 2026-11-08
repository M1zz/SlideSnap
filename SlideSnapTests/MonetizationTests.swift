//
//  MonetizationTests.swift
//  SlideSnapTests
//
//  **돈을 낸 사람은 잃지 않고, 선물 · 팁은 아무것도 열지 않는다.**
//
//  지키는 것:
//  - 권한 래치: 평생은 보이면 바로 붙들고, 조회가 비었다고 내리지 않는다. 내리는 것은 환불을 확인했을 때뿐.
//    구독은 만료일이 있는 표식이라 만료일이 지나면 저절로 닫힌다.
//  - 선물 · 팁 상품은 판매 · 권한 상품과 겹치지 않는다. 선물은 App Store 오퍼 코드로 받는 평생 상품만 가리킨다.
//  - 기존 사용자: 유료 앱일 때(빌드 11 까지) 받은 사람은 Pro 평생이다.
//

import XCTest
import LeeoKit
@testable import SlideSnap

final class PlanLatchTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: 올리기

    func test_평생을_사면_그_칸을_붙든다() {
        var latch = PlanLatch()
        latch.raise(owned: [ProProduct.plusLifetime], grandfathered: false)
        XCTAssertEqual(latch.tier(now: now), .plus)
        latch.raise(owned: [ProProduct.upgrade], grandfathered: false)
        XCTAssertEqual(latch.tier(now: now), .pro)
    }

    func test_조회가_비어도_내리지_않는다() {
        var latch = PlanLatch()
        latch.raise(owned: [ProProduct.proLifetime], grandfathered: false)
        latch.raise(owned: [], grandfathered: false)
        XCTAssertEqual(latch.tier(now: now), .pro, "App Store 로그아웃 한 번으로 산 칸이 사라지면 안 된다")
    }

    func test_구독은_평생으로_붙들지_않는다() {
        var latch = PlanLatch()
        latch.raise(owned: [ProProduct.proYearly, ProProduct.plusMonthly], grandfathered: false)
        XCTAssertEqual(latch.lifetime, .free)
    }

    // MARK: 구독 표식

    func test_구독은_만료일까지만_연다() {
        var latch = PlanLatch()
        latch.mark(subscription: ProProduct.proYearly, expiresAt: now.addingTimeInterval(3600))
        XCTAssertEqual(latch.tier(now: now), .pro)
        XCTAssertEqual(latch.tier(now: now.addingTimeInterval(7200)), .free, "만료일이 지나면 저절로 닫힌다")
    }

    func test_구독이_끝나도_평생은_남는다() {
        var latch = PlanLatch()
        latch.raise(owned: [ProProduct.plusLifetime], grandfathered: false)
        latch.mark(subscription: ProProduct.proMonthly, expiresAt: now.addingTimeInterval(-1))
        XCTAssertEqual(latch.tier(now: now), .plus)
    }

    func test_구독이_아닌_상품은_표식이_되지_않는다() {
        var latch = PlanLatch()
        latch.mark(subscription: ProProduct.proLifetime, expiresAt: now.addingTimeInterval(3600))
        latch.mark(subscription: ProProduct.giftPro, expiresAt: now.addingTimeInterval(3600))
        XCTAssertNil(latch.subscription)
    }

    // MARK: 내리기 (환불)

    func test_결제_기록이_비면_환불이_아니다() {
        var latch = PlanLatch(lifetime: .pro)
        latch.mark(subscription: ProProduct.plusYearly, expiresAt: now.addingTimeInterval(3600))
        latch.applyRefunds([])
        XCTAssertEqual(latch.lifetime, .pro)
        XCTAssertNotNil(latch.subscription)
    }

    func test_살아_있는_결제는_내리지_않는다() {
        var latch = PlanLatch(lifetime: .pro)
        latch.applyRefunds([.init(productID: ProProduct.proLifetime, revoked: false)])
        XCTAssertEqual(latch.lifetime, .pro)
    }

    func test_환불을_확인하면_남은_칸으로_내린다() {
        var latch = PlanLatch(lifetime: .pro)
        latch.applyRefunds([.init(productID: ProProduct.plusLifetime, revoked: false),
                            .init(productID: ProProduct.upgrade, revoked: true)])
        XCTAssertEqual(latch.lifetime, .plus, "올리기만 환불했으면 Plus 평생은 남는다")

        latch.applyRefunds([.init(productID: ProProduct.plusLifetime, revoked: true)])
        XCTAssertEqual(latch.lifetime, .free)
    }

    func test_환불_뒤_다시_샀으면_그대로다() {
        var latch = PlanLatch(lifetime: .pro)
        latch.applyRefunds([.init(productID: ProProduct.proLifetime, revoked: true),
                            .init(productID: ProProduct.proLifetime, revoked: false)])
        XCTAssertEqual(latch.lifetime, .pro)
    }

    func test_낮은_칸의_환불은_높은_칸을_내리지_않는다() {
        var latch = PlanLatch(lifetime: .pro)
        latch.applyRefunds([.init(productID: ProProduct.plusLifetime, revoked: true)])
        XCTAssertEqual(latch.lifetime, .pro, "Pro 평생의 근거가 환불된 것이 아니다(예: 유료 앱일 때 산 사람)")
    }

    func test_구독_환불은_모두_환불됐을_때만_지운다() {
        var latch = PlanLatch()
        latch.mark(subscription: ProProduct.proYearly, expiresAt: now.addingTimeInterval(3600))
        latch.applyRefunds([.init(productID: ProProduct.proYearly, revoked: true),
                            .init(productID: ProProduct.proYearly, revoked: false)])
        XCTAssertNotNil(latch.subscription)
        latch.applyRefunds([.init(productID: ProProduct.proYearly, revoked: true)])
        XCTAssertNil(latch.subscription)
    }

    // MARK: 보관

    func test_Keychain_에_적고_다시_읽는다() {
        let service = "com.leeo.slidesnap.tests.latch"
        PlanLatch.clear(service: service)
        defer { PlanLatch.clear(service: service) }

        XCTAssertEqual(PlanLatch.load(service: service), PlanLatch())
        var latch = PlanLatch(lifetime: .plus)
        latch.mark(subscription: ProProduct.proYearly, expiresAt: now)
        latch.save(service: service)
        XCTAssertEqual(PlanLatch.load(service: service), latch)

        latch.lifetime = .pro
        latch.save(service: service)
        XCTAssertEqual(PlanLatch.load(service: service).lifetime, .pro, "두 번째 저장은 덮어쓴다")
    }
}

// MARK: - 기존 사용자

final class PaidDownloadBuyerTests: XCTestCase {

    func test_유료_앱일_때_받은_빌드는_Pro_평생이다() {
        XCTAssertEqual(PaidDownloadBuyer.lastPaidBuild, 11, "한 번 나가면 바꾸지 않는다")
        for build in ["1", "5", "11", "11.0"] {
            XCTAssertTrue(PaidDownloadBuyer.isPaidDownload(originalAppVersion: build), build)
        }
    }

    func test_무료가_된_뒤_받은_빌드는_아니다() {
        for build in ["12", "13", "100", "", "abc"] {
            XCTAssertFalse(PaidDownloadBuyer.isPaidDownload(originalAppVersion: build), build)
        }
    }

    func test_유료_앱일_때_산_사람은_래치로_Pro_를_지킨다() {
        var latch = PlanLatch()
        latch.raise(owned: [], grandfathered: true)
        XCTAssertEqual(latch.tier(), .pro)
        // 다시 깔아 확인이 아직 안 된 실행에서도, 결제 기록이 없는 사람에게도 내려가지 않는다.
        latch.raise(owned: [], grandfathered: false)
        latch.applyRefunds([])
        XCTAssertEqual(latch.tier(), .pro)
    }
}

// MARK: - 선물 · 팁

final class GiftAndTipProductTests: XCTestCase {

    private var config: LeeoPaywallConfig { SlideSnapSpec.paywall! }

    /// 판매 상품과 권한 상품 전부. 선물 · 팁이 여기 들어가면 그것을 산 사람이 그 칸이 된다.
    private var sold: Set<String> {
        Set(config.productIDs).union(config.entitlementIDs).union(ProProduct.all).union(ProProduct.tierByProduct.keys)
    }

    func test_선물_상품은_판매_상품과_겹치지_않는다() {
        XCTAssertEqual(config.gifts.map(\.productID), ["com.leeo.slidesnap.gift.pro", "com.leeo.slidesnap.gift.plus"])
        XCTAssertTrue(sold.isDisjoint(with: config.gifts.map(\.productID)))
    }

    func test_팁_상품은_판매_상품과_겹치지_않는다() {
        XCTAssertEqual(config.tipJar?.productIDs, ProProduct.tips)
        XCTAssertTrue(sold.isDisjoint(with: ProProduct.tips))
        XCTAssertTrue(Set(ProProduct.tips).isDisjoint(with: config.gifts.map(\.productID)))
    }

    /// 선물은 App Store 오퍼 코드로만 간다. 앱이 만든 코드로 칸을 여는 길은 지침 3.1.1 에 걸린다.
    /// 그래서 선물이 가리키는 것은 받는 사람이 App Store 에서 받는 **평생 상품** 하나뿐이다.
    func test_선물은_오퍼_코드로_받는_평생_상품만_가리킨다() {
        let gifts = config.gifts
        XCTAssertEqual(gifts.map(\.grantsProductID), [ProProduct.proLifetime, ProProduct.plusLifetime])
        XCTAssertTrue(gifts.allSatisfy(\.sellsGifts))
        XCTAssertTrue(gifts.allSatisfy { $0.containerIdentifier == "iCloud.com.Ysoup.FeedbackHub" })
        // Pro 는 번들 ID 묶음, Plus 는 허브와 약속한 따로 된 묶음.
        XCTAssertNil(gifts[0].poolKey)
        XCTAssertEqual(gifts[1].poolKey, "com.leeo.slidesnap#com.leeo.slidesnap.plus")
        XCTAssertEqual(gifts.map(\.tierName), ["Pro", "Plus"])
    }

    func test_계약과_페이월_구성이_같은_선물_팁을_싣는다() {
        guard case .freemiumSubscription(let contract) = SlideSnapSpec.monetization else {
            return XCTFail("수익 모델이 바뀌었다")
        }
        XCTAssertEqual(([contract.gift].compactMap { $0 } + contract.moreGifts).map(\.productID),
                       config.gifts.map(\.productID))
        XCTAssertEqual(contract.tipJar?.productIDs, config.tipJar?.productIDs)
    }

    func test_사전_점검에_결제_오류가_없다() {
        let codes = LeeoPreflight.audit(SlideSnapSpec.self)
            .filter { $0.severity == .error }
            .map(\.code)
            .filter { $0.hasPrefix("gift.") || $0.hasPrefix("tip.") || $0.hasPrefix("paywall.") }
        XCTAssertTrue(codes.isEmpty, "\(codes)")
    }

    func test_선물_팁은_칸을_열지_않는다() {
        XCTAssertEqual(ProProduct.tier(owning: Set(ProProduct.tips + [ProProduct.giftPro, ProProduct.giftPlus])), .free)
        var latch = PlanLatch()
        latch.raise(owned: Set([ProProduct.giftPro, ProProduct.giftPlus] + ProProduct.tips), grandfathered: false)
        XCTAssertEqual(latch.tier(), .free)
    }
}
