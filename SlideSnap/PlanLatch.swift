//
//  PlanLatch.swift
//  SlideSnap
//
//  **돈을 낸 칸은 조회가 비었다고 내려가지 않는다.**
//
//  `Transaction.currentEntitlements` 는 App Store 로그아웃 · 기기 초기화 직후 · StoreKit 캐시가 서기 전에도
//  조용히 빈 값을 낸다. 그 한 번에 칸을 내리면 산 사람에게 페이월이 다시 뜬다. 그래서
//   · 평생(과 유료 앱일 때 산 사람)은 Keychain 에 적는다 — 앱을 지웠다 받아도 남는다.
//     내리는 근거는 환불을 `Transaction.all` 로 **직접 확인했을 때** 하나뿐이다.
//   · 구독은 래치가 아니라 **만료일이 있는 표식**이다. 만료일이 지나면 저절로 닫히고, 지우는 것은 환불뿐이다.
//
//  올리는 근거(권한이 보인다)는 확실하고, 내리는 근거(권한이 안 보인다)는 확실하지 않다. 그래서 둘이 대칭이 아니다.
//

import Foundation
import Security

struct PlanLatch: Equatable, Codable {
    /// 평생으로 가진 칸 (유료 앱일 때 산 사람은 Pro).
    var lifetime: ProTier = .free
    /// 살아 있던 구독과 그 만료일.
    var subscription: Mark?

    struct Mark: Equatable, Codable {
        let tier: ProTier
        let expiresAt: Date
    }

    /// 지금 이 래치가 여는 칸.
    func tier(now: Date = Date()) -> ProTier {
        guard let subscription, subscription.expiresAt > now else { return lifetime }
        return max(lifetime, subscription.tier)
    }

    // MARK: 올리기 — 보이면 바로

    /// StoreKit 이 지금 보여 준 권한으로 올린다. **내리지 않는다.**
    mutating func raise(owned: Set<String>, grandfathered: Bool) {
        let bought = ProProduct.tier(owning: owned.intersection(ProProduct.lifetimeIDs))
        lifetime = max(lifetime, bought, grandfathered ? .pro : .free)
    }

    /// 살아 있는 구독을 적는다. 구독이 안 보인다고 지우지 않는다 — 만료일이 닫는다.
    mutating func mark(subscription productID: String, expiresAt: Date) {
        guard let tier = ProProduct.tierByProduct[productID], ProProduct.subscriptionIDs.contains(productID) else { return }
        subscription = Mark(tier: tier, expiresAt: expiresAt)
    }

    // MARK: 내리기 — 환불을 확인했을 때만

    /// `Transaction.all` 에서 읽은 이 앱 상품의 결제들 (환불됐으면 revoked).
    struct Payment: Equatable {
        let productID: String
        let revoked: Bool
    }

    /// 환불을 반영한다.
    /// - 결제 기록이 **비어 있으면 아무것도 내리지 않는다.** 비었다는 것은 환불의 근거가 아니라 근거가 없다는 뜻이다.
    /// - 평생: 래치한 칸의 결제가 환불됐고, 그 칸 이상을 여는 살아 있는 평생 결제가 없을 때만 남은 칸으로 내린다.
    /// - 구독: 표식의 칸을 여는 구독 결제가 **모두** 환불됐을 때만 지운다.
    mutating func applyRefunds(_ payments: [Payment]) {
        func tier(_ p: Payment) -> ProTier { ProProduct.tierByProduct[p.productID] ?? .free }

        let lifetimes = payments.filter { ProProduct.lifetimeIDs.contains($0.productID) }
        let live = lifetimes.filter { !$0.revoked }.map(tier).max() ?? .free
        if live < lifetime, lifetimes.contains(where: { $0.revoked && tier($0) >= lifetime }) {
            lifetime = live
        }

        if let subscription {
            let same = payments.filter { ProProduct.subscriptionIDs.contains($0.productID) && tier($0) == subscription.tier }
            if !same.isEmpty, same.allSatisfy(\.revoked) { self.subscription = nil }
        }
    }
}

// MARK: - 보관 (Keychain)

extension PlanLatch {
    private static let account = "slidesnap.plan.latch"

    /// Keychain 에 둔 래치. 없으면 빈 래치.
    static func load(service: String = Bundle.main.bundleIdentifier ?? "com.leeo.slidesnap") -> PlanLatch {
        var query = baseQuery(service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let latch = try? JSONDecoder().decode(PlanLatch.self, from: data) else { return PlanLatch() }
        return latch
    }

    func save(service: String = Bundle.main.bundleIdentifier ?? "com.leeo.slidesnap") {
        guard let data = try? JSONEncoder().encode(self) else { return }
        let query = Self.baseQuery(service)
        let update = [kSecValueData as String: data]
        if SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func clear(service: String) {
        SecItemDelete(baseQuery(service) as CFDictionary)
    }

    private static func baseQuery(_ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}

extension ProTier: Codable {}
