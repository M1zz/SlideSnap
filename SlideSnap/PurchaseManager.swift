//
//  PurchaseManager.swift
//  SlideSnap
//
//  장표스냅 Plus · Pro 를 파는 자리. **속은 전부 `LeeoStore`다.**
//  상품 로드 · 구매 · 복원 · 거래 리스너(다른 기기, 가족 공유, 환불, 구독 만료) · 팁은 LeeoStore 안에 있고,
//  여기서는 그 값을 칸(`ProTier`)으로 읽고, 공유 확장이 볼 한 줄(또렷하게 보정)을 옮겨 적는다.
//

import Foundation
import Combine
import StoreKit
import SwiftUI
import LeeoKit

@MainActor
final class PurchaseManager: ObservableObject {

    static let shared = PurchaseManager()

    let store: LeeoStore

    /// 지금 쓰는 칸. 화면은 전부 이 값(과 `allows`)만 본다.
    @Published private(set) var tier: ProTier = .free

    /// **이번 실행에서 영수증을 실제로 읽었는가.** false 면 화면은 '무료'라고 단정하지 않는다.
    @Published private(set) var isKnown = false

    /// **유료 칸 상품을 한 번이라도 불러왔는가.**
    ///
    /// 상품이 App Store Connect 에 서기 전에 이 빌드가 나가면 아무도 살 수 없다. 그때 무료 한도로 막으면
    /// 막히는 사람만 생기므로, 한 번도 못 불러온 기기는 모두 열어 둔다. 한 번 불러온 기기는 그 뒤로
    /// 네트워크가 잠깐 끊겨도 다시 막는다(그때는 살 길이 있다).
    @Published private(set) var sellsPaid: Bool

    @Published private(set) var products: [Product] = []
    @Published private(set) var ownedProductIDs: Set<String> = []
    /// 지금 살아 있는 구독. 있으면 내 정보에 '구독 관리' · '평생으로 바꾸기'가 선다.
    @Published private(set) var subscription: LeeoGraduation.Subscription?
    @Published private(set) var isWorking = false
    /// 사다가 막혔을 때 화면에 그대로 보여 줄 말.
    @Published private(set) var failureMessage: String?

    private static let sellsPaidKey = "slidesnap.plan.sellsPaid"
    private var observation: AnyCancellable?

    private init() {
        guard let config = SlideSnapSpec.paywall else {
            preconditionFailure("계약에 페이월이 없다. SlideSnapSpec.monetization 을 확인할 것")
        }
        store = LeeoStore(config: config, grandfather: { await PaidDownloadBuyer.boughtBeforeFree() })
        sellsPaid = UserDefaults.standard.bool(forKey: Self.sellsPaidKey)
        // ⚠️ objectWillChange 는 값이 바뀌기 **직전**에 온다. 다음 차례로 미뤄서 읽는다.
        observation = store.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.pull() }
        }
        pull()
    }

    /// 이 기능을 써도 되는가.
    func allows(_ feature: ProFeature) -> Bool {
        #if DEBUG
        if DemoMode.screen != nil { return true }   // 스크린샷에 자물쇠가 찍히지 않게
        #endif
        return !sellsPaid || tier >= feature.tier
    }

    /// 발표를 하나 더 만들 수 있는가 (`count` = 지금 목록의 발표 수).
    func canAddPresentation(having count: Int) -> Bool {
        allows(.unlimitedPresentations) || count < FreeLimit.presentations
    }

    /// 상품 하나. 아직 못 불러왔으면 nil.
    func product(_ id: String) -> Product? { products.first { $0.id == id } }

    /// 유료 앱일 때 사서 Pro 인가.
    var isGrandfathered: Bool { store.isGrandfathered }

    var ownsPlusLifetime: Bool { ownedProductIDs.contains(ProProduct.plusLifetime) }

    /// 팁(응원). 기능을 열지 않는다.
    var tipJar: LeeoTipJar {
        guard let tipJar = store.tipJar else { preconditionFailure("계약에 팁이 없다. SlideSnapSpec.monetization 을 확인할 것") }
        return tipJar
    }

    // MARK: - 상태 맞추기

    /// 영수증을 다시 읽고 상품을 불러온다. 앱이 켜질 때와 앞으로 돌아올 때마다 부른다.
    func refresh() async {
        await store.refreshEntitlements()
        await store.loadProducts()
        subscription = await LeeoGraduation.currentSubscription(among: ProProduct.subscriptionIDs)
        isKnown = true
        pull()
    }

    func loadProducts() async {
        await store.loadProducts()
        pull()
    }

    /// **구독 졸업을 제안할 때인가.** 6개월째와 갱신 7일 전에 한 번씩. 띄운 쪽이 `markGraduationOffered()`.
    var graduationIsDue: Bool {
        guard let subscription, product(ProProduct.graduate) != nil else { return false }
        return LeeoGraduation.isDue(subscription, lastOffered: LeeoGraduation.lastOffered())
    }

    func markGraduationOffered() { LeeoGraduation.markOffered() }

    // MARK: - 사기 / 되찾기

    /// ⚠️ `action` 은 화면의 `@Environment(\.purchase)`. 아이패드에서 결제 시트가 엉뚱한 창에 뜨지 않게.
    func purchase(_ product: Product, using action: PurchaseAction) async {
        _ = await store.purchase(product) { try await action($0) }
        isKnown = true
        subscription = await LeeoGraduation.currentSubscription(among: ProProduct.subscriptionIDs)
        pull()
    }

    /// 기기를 바꿨거나 앱을 지웠다 받은 사람이 되찾는 길. 심사에서도 요구한다.
    func restore() async {
        await store.restore()
        isKnown = true
        subscription = await LeeoGraduation.currentSubscription(among: ProProduct.subscriptionIDs)
        pull()
        if tier == .free, failureMessage == nil {
            failureMessage = String(localized: "이 Apple 계정에서 구매한 기록을 찾지 못했어요.")
        }
    }

    // MARK: -

    private func pull() {
        products = store.products
        ownedProductIDs = store.purchasedProductIDs
        tier = store.isGrandfathered ? .pro : ProProduct.tier(owning: store.purchasedProductIDs)
        isWorking = store.purchasingProductID != nil || store.isRestoring
        failureMessage = store.lastError

        if !sellsPaid, products.contains(where: { ProProduct.tierByProduct[$0.id] != nil }) {
            sellsPaid = true
            UserDefaults.standard.set(true, forKey: Self.sellsPaidKey)
        }

        // 공유 확장은 결제를 모른다. 또렷하게 보정 단추를 세울지 한 줄로 옮겨 적는다.
        // 영수증을 읽기 전에는 적지 않는다 — 산 사람의 단추가 사라지면 안 된다.
        if isKnown { ShareInbox.enhanceUnlocked = allows(.enhance) }
    }
}
