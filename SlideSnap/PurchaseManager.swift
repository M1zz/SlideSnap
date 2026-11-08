//
//  PurchaseManager.swift
//  SlideSnap
//
//  장표스냅 Plus · Pro 를 파는 자리. **속은 전부 `LeeoStore`다.**
//  상품 로드 · 구매 · 복원 · 거래 리스너(다른 기기, 가족 공유, 환불, 구독 만료) · 팁은 LeeoStore 안에 있고,
//  여기서는 그 값을 칸(`ProTier`)으로 읽고, 공유 확장이 볼 한 줄(또렷하게 보정)을 옮겨 적는다.
//
//  칸은 **래치**로 읽는다(→ PlanLatch). 평생은 Keychain 에, 구독은 만료일과 함께 적고, 내리는 것은 환불을 확인했을 때뿐.
//  권한은 앱을 켤 때 · 앞으로 돌아올 때 · 코드를 쓴 뒤(App Store 오퍼 코드, 선물) 다시 읽는다.
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
    /// 지금 살아 있는 구독. 있으면 설정에 '구독 관리' · '평생으로 바꾸기'가 선다.
    @Published private(set) var subscription: LeeoGraduation.Subscription?
    @Published private(set) var isWorking = false
    /// 사다가 막혔을 때 화면에 그대로 보여 줄 말.
    @Published private(set) var failureMessage: String?

    private static let sellsPaidKey = "slidesnap.plan.sellsPaid"
    private var observations: [AnyCancellable] = []
    /// 산 칸을 붙드는 래치. 바뀔 때마다 Keychain 에 적는다.
    private var latch = PlanLatch.load()

    private init() {
        guard let config = SlideSnapSpec.paywall else {
            preconditionFailure("계약에 페이월이 없다. SlideSnapSpec.monetization 을 확인할 것")
        }
        store = LeeoStore(config: config, grandfather: { await PaidDownloadBuyer.boughtBeforeFree() })
        sellsPaid = UserDefaults.standard.bool(forKey: Self.sellsPaidKey)
        // ⚠️ objectWillChange 는 값이 바뀌기 **직전**에 온다. 다음 차례로 미뤄서 읽는다.
        observations.append(store.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.pull() }
        })
        // 받은 오퍼 코드가 그 칸을 열었다(선물 받기 화면) — 권한을 다시 읽는다.
        for gift in store.gifts {
            observations.append(gift.$ownsGrantedProduct.removeDuplicates().filter { $0 }.sink { [weak self] _ in
                Task { await self?.refresh() }
            })
            // 선물 상품이 불러와지거나 보낸 선물이 바뀌면 설정의 선물 줄도 다시 그린다.
            observations.append(gift.objectWillChange.sink { [weak self] _ in
                Task { @MainActor in self?.objectWillChange.send() }
            })
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

    /// Plus 평생을 가졌는가(래치). 그러면 Pro 평생은 올리기(차액) 상품으로 판다.
    var ownsPlusLifetime: Bool {
        #if DEBUG
        if ReviewShot.productID == ProProduct.upgrade { return true }   // 올리기 상품의 심사 이미지
        #endif
        return latch.lifetime >= .plus
    }

    /// 파는 선물(Pro · Plus). 받는 사람의 칸은 App Store 오퍼 코드로 정식 구매가 되어 들어온다.
    var gifts: [LeeoGiftStore] { store.gifts }

    /// 팁(응원). 기능을 열지 않는다.
    var tipJar: LeeoTipJar {
        guard let tipJar = store.tipJar else { preconditionFailure("계약에 팁이 없다. SlideSnapSpec.monetization 을 확인할 것") }
        return tipJar
    }

    // MARK: - 상태 맞추기

    /// 영수증을 다시 읽고 상품을 불러온다. 앱이 켜질 때 · 앞으로 돌아올 때 · 코드를 쓴 뒤에 부른다.
    func refresh() async {
        await store.refreshEntitlements()
        await store.loadProducts()
        await readSubscription()
        isKnown = true
        pull()
        // 래치가 StoreKit 보다 높은 칸을 붙들고 있을 때만 환불을 확인한다. 그때 말고는 볼 까닭이 없다.
        if latch.tier() > liveTier { await checkRefunds() }
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
        await readSubscription()
        pull()
    }

    /// 기기를 바꿨거나 앱을 지웠다 받은 사람이 되찾는 길. 심사에서도 요구한다.
    func restore() async {
        await store.restore()
        isKnown = true
        await readSubscription()
        pull()
        if tier == .free, failureMessage == nil {
            failureMessage = String(localized: "이 Apple 계정에서 구매한 기록을 찾지 못했어요.")
        }
    }

    // MARK: -

    /// StoreKit 이 지금 보여 주는 칸 (래치 없이).
    private var liveTier: ProTier {
        store.isGrandfathered ? .pro : ProProduct.tier(owning: store.purchasedProductIDs)
    }

    /// 살아 있는 구독을 읽어 래치에 만료일과 함께 적는다. 안 보이면 그대로 둔다 — 만료일이 닫는다.
    private func readSubscription() async {
        subscription = await LeeoGraduation.currentSubscription(among: ProProduct.subscriptionIDs)
        if let subscription, let expires = subscription.renewsAt {
            update { $0.mark(subscription: subscription.productID, expiresAt: expires) }
        }
    }

    /// 환불 확인 — `Transaction.all` 은 환불된 결제도 내보낸다(`currentEntitlements` 는 아예 빼서 "환불"과
    /// "조회가 비었다"를 가를 수 없다).
    private func checkRefunds() async {
        let ids = Set(ProProduct.tierByProduct.keys)
        var payments: [PlanLatch.Payment] = []
        for await result in Transaction.all {
            guard case .verified(let tx) = result, ids.contains(tx.productID) else { continue }
            payments.append(.init(productID: tx.productID, revoked: tx.revocationDate != nil))
        }
        update { $0.applyRefunds(payments) }
        pull()
    }

    private func update(_ change: (inout PlanLatch) -> Void) {
        var next = latch
        change(&next)
        guard next != latch else { return }
        latch = next
        latch.save()
    }

    private func pull() {
        products = store.products
        ownedProductIDs = store.purchasedProductIDs
        update { $0.raise(owned: store.purchasedProductIDs, grandfathered: store.isGrandfathered) }
        tier = max(liveTier, latch.tier())
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
