//
//  ReviewShot.swift
//  SlideSnap
//
//  인앱 상품 **심사용 이미지** 장면 (DEBUG 빌드 전용 — 출시 빌드에는 들어가지 않는다).
//  실행 인자로 상품 하나를 고르면 그 상품을 사는 화면으로 앱을 덮는다.
//
//    -reviewShot <상품 ID> [-reviewShotPrice '<값>']
//
//   · 선물(gift.plus · gift.pro): 선물 화면을 결제 없이 그린다(LeeoKit `LeeoGiftView(previewPrice:)`).
//   · 팁(tip.small · medium · large): 응원 화면을 결제 없이 그린다(`LeeoTipJarView(previewPrices:)`).
//     이 두 갈래는 상품을 불러오지 않으므로 `xcrun simctl launch` 로 띄워도 값이 선다.
//   · 구독 · 평생 · 올리기: 페이월에서 그 칸 · 그 길을 골라 둔다. 졸업가: 졸업 제안 화면.
//     실제 상품을 불러와야 값이 서므로 **Xcode 에서 SlideSnap 스킴으로 실행**한다(스킴에 SlideSnap.storekit 이 걸려 있다).
//
//      xcrun simctl launch <기기> com.leeo.slidesnap -reviewShot com.leeo.slidesnap.gift.pro -reviewShotPrice '$35.99'
//

#if DEBUG
import SwiftUI
import LeeoKit

enum ReviewShot {
    /// 찍을 상품. 없으면 평소 화면.
    static var productID: String? { UserDefaults.standard.string(forKey: "reviewShot") }
    /// 화면에 적을 값. 없으면 SlideSnap.storekit 의 미국 값.
    static var price: String? { UserDefaults.standard.string(forKey: "reviewShotPrice") }

    /// SlideSnap.storekit 과 같은 미국 값 — 결제 없이 그리는 두 갈래(선물 · 팁)의 기본값.
    static let defaultPrices: [String: String] = [
        ProProduct.giftPro: "$35.99", ProProduct.giftPlus: "$23.99",
        ProProduct.tips[0]: "$0.99", ProProduct.tips[1]: "$2.99", ProProduct.tips[2]: "$9.99",
    ]

    static func price(of id: String) -> String {
        (id == productID ? price : nil) ?? defaultPrices[id] ?? "$9.99"
    }
}

extension View {
    /// `-reviewShot` 이 있으면 앱 대신 그 상품의 심사 이미지 장면을 세운다.
    /// (덮지 않고 바꾼다 — 켜자마자 뜨는 카메라 화면이 덮개 위로 올라온다.)
    @ViewBuilder
    func reviewShotScene() -> some View {
        if let productID = ReviewShot.productID {
            ReviewShotView(productID: productID)
        } else {
            self
        }
    }
}

private struct ReviewShotView: View {
    let productID: String
    @ObservedObject private var purchases = PurchaseManager.shared

    var body: some View {
        NavigationStack {
            scene
        }
        .background(Color(.systemBackground).ignoresSafeArea())
    }

    @ViewBuilder
    private var scene: some View {
        if let gift = purchases.gifts.first(where: { $0.config.productID == productID }) {
            LeeoGiftView<SlideSnapSpec>(previewPrice: ReviewShot.price(of: productID), gift: gift)
                .navigationTitle("선물하기")
                .navigationBarTitleDisplayMode(.inline)
        } else if ProProduct.tips.contains(productID) {
            LeeoTipJarView<SlideSnapSpec>(previewPrices: ProProduct.tips.map(ReviewShot.price(of:)))
        } else if productID == ProProduct.graduate {
            LeeoGraduationOfferView(graduate: purchases.product(productID)) {}
        } else if ProProduct.tierByProduct[productID] != nil {
            // 고르는 일은 PaywallView 가 `ReviewShot.productID` 를 보고 한다.
            PaywallView(embedded: true)
        } else {
            Text(verbatim: "no product \(productID)")
        }
    }
}
#endif
