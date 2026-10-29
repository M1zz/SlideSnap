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

    /// 인앱 결제 없음.
    static let monetization = LeeoMonetization.free

    /// App Store 앱 ID — 리뷰 링크 · 친구에게 소개하기에 쓴다.
    static var appStoreID: String? { "6790835318" }
}

// MARK: - 팁 (개발자 응원하기)

/// 무료 앱이라 LeeoStore 가 없다. 팁 엔진을 여기 하나 두고, 앱을 열 때 `startStandalone()` 을 부른다.
@MainActor
enum SlideSnapTip {
    static let tipJar = LeeoTipJar(config: LeeoTipJarConfig(productIDs: [
        "com.leeo.slidesnap.tip.small",
        "com.leeo.slidesnap.tip.medium",
        "com.leeo.slidesnap.tip.large",
    ]))
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
