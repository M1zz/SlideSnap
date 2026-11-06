//
//  SlideSnapSpec.swift
//  SlideSnap
//
//  LeeoKit 계약(LeeoAppSpec) 준수 — 이 앱의 공통 기능 설정값 단일 소스.
//  피드백 시스템 구현은 전부 LeeoKit에 있고, 앱은 이 설정만 제공한다.
//
//  ⚠️ feedback의 컨테이너/레코드 타입/구독 ID는 CloudKit Dashboard·기존 사용자
//  기기와의 계약이다 — 변경 금지.
//

import Foundation
import LeeoKit

enum SlideSnapSpec: LeeoAppSpec {
    static let appName = "장표스냅"
    static let developerEmail = AppInfo.developerEmail

    /// SlideSnap.entitlements의 iCloud 컨테이너와 동일해야 한다.
    /// 공용 피드백 허브(FeedbackHub)로 수집 — appIdentifier로 앱을 구분한다.
    static let feedback = LeeoFeedbackConfig(
        containerIdentifier: "iCloud.com.Ysoup.FeedbackHub",
        appIdentifier: "com.leeo.slidesnap"
    )

    /// 정책 링크 — APPSTORE.md 의 지원 URL · 개인정보 처리방침 URL 과 같은 주소.
    static let legal = LeeoLegalConfig(
        privacyURL: URL(string: "https://m1zz.github.io/SlideSnap/privacy.html")!,
        supportURL: URL(string: "https://m1zz.github.io/SlideSnap/")!,
        marketingURL: URL(string: "https://m1zz.github.io/SlideSnap/")!
    )

    /// 수익모델 — 무료로 찍고 펴고 묶다가, 한 학기를 통째로 담으면 Plus, 그때 한 말까지 담으면 Pro.
    /// 칸마다 주 · 월 · 연 구독과 평생. 무엇이 어느 칸인지는 `ProFeature.tier` 한 곳에 있다 (→ Plan.swift).
    /// 1.0.11 까지는 유료 다운로드 앱이었고, 그때 산 사람은 Pro 평생이다 (→ PaidDownloadBuyer).
    static let monetization = LeeoMonetization.freemiumSubscription(
        LeeoSubscriptionConfig(
            productIDs: ProProduct.all,
            // 자체 약관이 없으므로 애플 표준 사용권 계약(EULA)을 건다. 구독을 파는 앱의 심사 필수 항목이다.
            termsURL: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!,
            entitlementIDs: Set(ProProduct.tierByProduct.keys),
            gate: LeeoGatePolicy(
                freeLimits: [Gate.presentations: FreeLimit.presentations],
                proOnly: Set(ProFeature.allCases.map(\.rawValue)).subtracting([ProFeature.unlimitedPresentations.rawValue])),
            // 개발자 응원 팁. ⚠️ 기능을 여는 상품이 아니다 — productIDs · entitlementIDs 에 넣지 않는다.
            tipJar: LeeoTipJarConfig(productIDs: ProProduct.tips)))

    /// 게이트 열쇠말 (무료 한도).
    enum Gate {
        static let presentations = "presentations"
    }

    /// 금고가 위젯과 함께 쓰는 공유 컨테이너도 백업한다.
    static let appGroups = ["group.com.leeo.slidesnap"]

    /// App Store 앱 ID — 리뷰 링크 · 친구에게 소개하기에 쓴다.
    static var appStoreID: String? { "6790835318" }
}

// MARK: - 팁 (개발자 응원하기)

/// 팁은 결제 리스너를 함께 쓰려고 LeeoStore 안에 둔다(→ PurchaseManager). 소모성 셋, 작은 것부터.
/// ⚠️ 기능을 여는 상품이 아니다. 응원 부탁은 이미 Pro 를 가진 사람에게만 한다(→ PresentationDetailView).
@MainActor
enum SlideSnapTip {
    static var tipJar: LeeoTipJar { PurchaseManager.shared.tipJar }
}

/// 팁을 부탁할 만한 순간 — 지금까지 담은 장표 수. 큰 것부터.
enum SlideSnapTipMoments {
    static let slides = [1000, 300, 100]

    static func reached(slideCount n: Int) -> [LeeoTipMoment] {
        slides.filter { n >= $0 }.map { threshold in
            LeeoTipMoment(id: "slides.\(threshold)",
                          message: String(localized: "지금까지 장표 \(n)장을 담았어요",
                                          comment: "Tip ask card: how many presentation slides the person has captured so far"))
        }
    }

    static func reachedNow(in presentations: [Presentation]) -> [LeeoTipMoment] {
        reached(slideCount: presentations.reduce(0) { $0 + $1.slides.count })
    }
}

/// 앱 전역에서 쓰는 상수 (기존 FeedbackService.swift에서 이동).
enum AppInfo {
    /// 피드백 이메일 폴백 수신 주소.
    static let developerEmail = "leeo@kakao.com"

    /// 현재 앱 버전 (예: "1.0").
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
    }
}
