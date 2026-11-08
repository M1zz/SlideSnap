//
//  Plan.swift
//  SlideSnap
//
//  장표스냅의 세 칸(무료 · Plus · Pro)과 칸마다 여는 것. **무엇이 잠기는지는 이 파일 한 곳에만 적는다.**
//  페이월의 비교표 · 잠긴 자리 · 설정의 '요금제와 응원'이 모두 여기서 읽는다.
//
//  선은 한 문장으로 긋는다 — "찍고 펴고 묶고 찾는 일은 무료, 한 학기를 통째로 담는 것은 Plus, 그때 한 말까지 담는 것은 Pro".
//   · 무료: 원근 보정 · 무음 · 자동 촬영, 발표별 묶기 · 합치기, 사진 앱 가져오기 · 공유 확장, 글자 인식 · 검색,
//           이미지 공유 · PDF 한 장씩, 위젯, 발표 10개
//   · Plus: 발표 무제한, 또렷하게 보정, PDF 두 장 · 네 장씩
//   · Pro:  Plus 전부 + 녹음 · 받아쓰기, 기기 안 요약, PowerPoint · Markdown 내보내기, iCloud 동기화
//
//  ⚠️ 이미 만든 발표 · 장표 · 녹음 · 받아쓴 글 · 요약은 칸과 관계없이 보고 듣고 내보내고 지울 수 있다.
//     잠그는 것은 **새로 만드는 것**과 **잠긴 것을 새로 켜는 것**뿐이다.
//

import Foundation
import StoreKit

/// 칸. 값이 클수록 더 많이 연다. Pro 는 Plus 를 전부 포함한다.
enum ProTier: Int, Comparable, CaseIterable {
    case free = 0
    case plus = 1
    case pro = 2

    static func < (lhs: ProTier, rhs: ProTier) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .free: String(localized: "무료")
        case .plus: String(localized: "장표스냅 Plus")
        case .pro:  String(localized: "장표스냅 Pro")
        }
    }
}

/// 값을 받고 여는 것들.
enum ProFeature: String, CaseIterable, Identifiable {
    /// 11번째 발표부터 (무료는 `FreeLimit.presentations` 개)
    case unlimitedPresentations
    /// 또렷하게 보정 (그림자 · 흐린 대비 걷어 내기)
    case enhance
    /// PDF 두 장씩 · 네 장씩
    case pdfLayouts
    /// 발표 녹음 · 기기 안 받아쓰기
    case recording
    /// 기기 안 Apple 언어 모델로 발표 요약
    case summary
    /// PowerPoint · Markdown 내보내기
    case notesExport
    /// iCloud 동기화
    case sync

    var id: String { rawValue }

    /// 이 기능을 여는 가장 낮은 칸.
    var tier: ProTier {
        switch self {
        case .unlimitedPresentations, .enhance, .pdfLayouts: .plus
        case .recording, .summary, .notesExport, .sync:      .pro
        }
    }
}

/// 무료 칸의 한도.
enum FreeLimit {
    /// 발표. 11번째 발표를 새로 만들려 할 때 페이월이 뜬다(찍은 장표는 막지 않는다 → PresentationListView).
    static let presentations = 10
}

// MARK: - 상품

/// App Store Connect · `SlideSnap.storekit` 과 **글자 하나까지 같아야 한다.**
///
/// 주 · 월 · 연 구독 여섯은 구독 그룹 하나에 넣는다(Pro 가 위 단계). 그래야 Plus 에서 Pro 로 갈아탈 수 있다.
/// ⚠️ 언제나 평생 패스는 팔지 않는다(포트폴리오 전체에서 판매를 멈췄다).
enum ProProduct {
    private static let prefix = "com.leeo.slidesnap"

    static let plusWeekly   = prefix + ".plus.weekly"
    static let plusMonthly  = prefix + ".plus.monthly"
    static let plusYearly   = prefix + ".plus.yearly"
    static let plusLifetime = prefix + ".plus"
    static let proWeekly    = prefix + ".pro.weekly"
    static let proMonthly   = prefix + ".pro.monthly"
    static let proYearly    = prefix + ".pro.yearly"
    static let proLifetime  = prefix + ".pro"
    /// Plus 평생을 산 사람이 Pro 평생으로 올리는 값.
    static let upgrade      = prefix + ".pro.upgrade"
    /// 구독 중인 사람의 졸업가 Pro 평생 (→ LeeoGraduation).
    static let graduate     = prefix + ".pro.graduate"

    /// 개발자 응원 팁. 아무것도 열지 않는다 — `all` · `tierByProduct` 에 넣지 않는다.
    static let tips = [prefix + ".tip.small", prefix + ".tip.medium", prefix + ".tip.large"]

    /// 선물(소모성, 몇 번이고 보낸다). 사면 받는 사람에게 같은 칸의 평생이 **App Store 오퍼 코드**로 간다.
    /// ⚠️ 산 사람에게는 아무것도 열지 않는다 — `all` · `tierByProduct` 에 넣지 않는다.
    static let giftPro  = prefix + ".gift.pro"
    static let giftPlus = prefix + ".gift.plus"
    /// Plus 선물의 오퍼 코드 묶음 열쇠. 허브(FeedbackHub)가 같은 열쇠로 묶음을 채운다. Pro 묶음은 번들 ID 그대로다.
    static let giftPlusPoolKey = prefix + "#" + plusLifetime

    /// 평생 상품. 이것만 래치(Keychain)에 적는다 (→ PlanLatch). 구독은 만료일이 있는 표식이다.
    static let lifetimeIDs: Set<String> = [plusLifetime, proLifetime, upgrade, graduate]

    /// 상품마다 여는 칸. 구독은 같은 칸의 평생과 같은 권한, 올리기 · 졸업은 Pro 평생이다.
    static let tierByProduct: [String: ProTier] = [
        plusWeekly: .plus, plusMonthly: .plus, plusYearly: .plus, plusLifetime: .plus,
        proWeekly: .pro, proMonthly: .pro, proYearly: .pro, proLifetime: .pro,
        upgrade: .pro, graduate: .pro,
    ]

    /// 페이월이 불러오는 상품.
    static let all = [plusYearly, plusLifetime, plusMonthly, plusWeekly,
                      proYearly, proLifetime, proMonthly, proWeekly,
                      upgrade, graduate]

    static let subscriptionIDs: Set<String> = [plusWeekly, plusMonthly, plusYearly,
                                               proWeekly, proMonthly, proYearly]

    /// 가진 상품들이 여는 칸. 가장 높은 것을 쓴다.
    static func tier(owning ids: Set<String>) -> ProTier {
        ids.compactMap { tierByProduct[$0] }.max() ?? .free
    }

    /// 칸마다 고르는 길 — 연이 기본, 평생, 그리고 펼쳐 보이는 월 · 주.
    enum Term: CaseIterable {
        case yearly, lifetime, monthly, weekly
    }

    /// 그 칸 · 그 길의 상품 ID. Plus 평생을 가진 사람의 Pro 평생은 올리기 상품이다.
    static func id(_ tier: ProTier, _ term: Term, ownsPlusLifetime: Bool = false) -> String {
        switch (tier, term) {
        case (.pro, .yearly):   proYearly
        case (.pro, .lifetime): ownsPlusLifetime ? upgrade : proLifetime
        case (.pro, .monthly):  proMonthly
        case (.pro, .weekly):   proWeekly
        case (_, .yearly):      plusYearly
        case (_, .lifetime):    plusLifetime
        case (_, .monthly):     plusMonthly
        case (_, .weekly):      plusWeekly
        }
    }
}

// MARK: - 유료 앱일 때 산 사람

/// 장표스냅은 1.0.11 까지 유료 다운로드(₩4,400) 앱이었다. 그때 산 사람은 무엇도 잃지 않게 Pro 평생으로 연다.
enum PaidDownloadBuyer {
    /// 유료 다운로드로 판 마지막 빌드(1.0.11 빌드 11). 페이월이 든 첫 빌드는 이보다 크다.
    /// ⚠️ 한 번 나가면 바꾸지 않는다. 올리면 무료로 받은 사람에게 공짜 Pro 가 생기고, 내리면 산 사람이 잠긴다.
    static let lastPaidBuild = 11

    /// App Store 가 서명한 최초 다운로드 빌드로 알아본다. 지웠다 다시 받아도 같다.
    /// 시험 환경(Xcode · 샌드박스 · TestFlight)은 최초 빌드가 늘 "1.0" 으로 오므로 출시 영수증만 믿는다.
    static func boughtBeforeFree() async -> Bool {
        guard case .verified(let app)? = try? await AppTransaction.shared,
              app.environment == .production else { return false }
        return isPaidDownload(originalAppVersion: app.originalAppVersion)
    }

    /// iOS 의 `originalAppVersion` 은 처음 받은 빌드의 CFBundleVersion(빌드 번호)이다.
    static func isPaidDownload(originalAppVersion: String) -> Bool {
        guard let build = Int(originalAppVersion.split(separator: ".").first ?? "") else { return false }
        return build <= lastPaidBuild
    }
}
