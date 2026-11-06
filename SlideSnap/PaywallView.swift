//
//  PaywallView.swift
//  SlideSnap
//
//  장표스냅의 세 칸(무료 · Plus · Pro)을 파는 한 장.
//
//  **무료인 것을 먼저 말한다.** 비교표 맨 위가 '원근 보정 · 무음 · 자동 촬영'이다 — 이 화면을 닫고 나서도
//  사는 사람도 안 사는 사람도 앱을 계속 쓴다. 그다음 Plus · Pro 칸, 칸마다 연 구독(기본) · 평생,
//  펼치면 월 · 주. 첫 해 할인(App Store 첫 구독 할인)은 처음 구독하는 사람에게만 보인다.
//
//  무엇이 어느 칸인지는 `ProFeature.tier` 한 곳에 있다 (→ Plan.swift).
//

import SwiftUI
import StoreKit
import LeeoKit

struct PaywallView: View {
    /// 어디서 들어왔는가. 그 기능의 줄과 그 기능이 든 칸을 짚는다.
    var highlight: ProFeature?
    /// 무료 발표를 다 채운 채 찍어서, 찍은 장표를 가장 최근 발표에 담았는가.
    var savedToRecent = false

    @ObservedObject private var purchases = PurchaseManager.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    /// 결제 시트를 **이 페이월이 떠 있는 창**에 띄운다 (→ PurchaseManager.purchase).
    @Environment(\.purchase) private var purchaseAction

    /// 칸마다 고른 길. 처음엔 연 구독.
    @State private var plusTerm: ProProduct.Term = .yearly
    @State private var proTerm: ProProduct.Term = .yearly
    /// 월 · 주 구독을 펼쳤는가.
    @State private var showsShortTerms = false
    /// 첫 구독 할인을 받을 수 있는 연 구독 상품.
    @State private var introEligible: Set<String> = []
    @State private var loadingProducts = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if let reason { reasonLine(reason) }
                    PlanComparisonTable(highlight: highlight)
                    plansStatus
                    // 들어온 자리의 칸이 먼저다.
                    ForEach(highlight?.tier == .pro ? [ProTier.pro, .plus] : [.plus, .pro], id: \.self) { tierCard($0) }
                    // 요금제를 못 불러온 것은 `plansStatus` 가 직접 말한다. 여기는 사다가 막힌 이유만.
                    if let message = purchases.failureMessage, !purchases.products.isEmpty {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.body)
                            .foregroundStyle(.orange)
                    }
                    legal
                }
                .padding(20)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("요금제")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("구매 복원") {
                        Task {
                            await purchases.restore()
                            if purchases.tier >= (highlight?.tier ?? .plus) { dismiss() }
                        }
                    }
                    .disabled(purchases.isWorking)
                }
            }
            // ⚠️ `.onAppear` 가 아니라 `.task` 다. NavigationStack 안의 onAppear 는 여러 번 불려 조회수를 부풀린다.
            .task {
                LeeoAnalyticsCenter.track(.paywallShown(reason: highlight?.rawValue ?? "profile"))
                await loadPlans()
            }
            .task(id: purchases.products.count) { await checkIntroEligibility() }
        }
    }

    // MARK: 머리

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("장표스냅 Plus · Pro")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text("한 학기를 통째로, 그때 한 말까지. 연 구독이나 평생 중에 고르세요.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("찍고 펴고 묶고 찾는 일은 계속 무료예요.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 한도에 부딪혀 들어왔을 때 무엇에 막혔는지, 하던 것은 어떻게 됐는지 먼저 말한다.
    private var reason: String? {
        if savedToRecent {
            return String(localized: "방금 찍은 장표는 가장 최근 발표에 담았어요. 새 발표로 따로 묶으려면 Plus가 필요해요.")
        }
        guard highlight == .unlimitedPresentations else { return nil }
        return String(localized: "무료로는 발표를 \(FreeLimit.presentations)개까지 만들어요. 이미 담은 발표는 그대로 보고 내보낼 수 있어요.")
    }

    private func reasonLine(_ text: String) -> some View {
        Label(text, systemImage: "info.circle.fill")
            .font(.body)
            .foregroundStyle(Color.accentColor)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: 유료 칸

    private func tierCard(_ tier: ProTier) -> some View {
        let highlighted = highlight?.tier == tier && purchases.tier < tier
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(tier.title)
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                if purchases.isKnown && purchases.tier == tier {
                    Text("지금 쓰는 칸")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
                Spacer(minLength: 0)
            }
            Text(tier == .plus ? String(localized: "한 학기, 한 학회를 통째로. 글자는 더 또렷하게.")
                               : String(localized: "그때 한 말까지 장표 옆에, 요약은 기기가 알아서."))
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // 이미 이 칸 이상이면 살 것이 없다. 구독을 평생으로 바꾸는 길은 내 정보에 있다.
            if purchases.tier < tier && !purchases.products.isEmpty {
                terms(for: tier)
                buyButton(tier)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            shape.fill(Color(.secondarySystemGroupedBackground))
            shape.strokeBorder(highlighted ? Color.accentColor : .clear, lineWidth: 2)
        }
    }

    private func term(for tier: ProTier) -> Binding<ProProduct.Term> {
        tier == .plus ? $plusTerm : $proTerm
    }

    private func productID(_ tier: ProTier, _ term: ProProduct.Term) -> String {
        ProProduct.id(tier, term, ownsPlusLifetime: purchases.ownsPlusLifetime)
    }

    @ViewBuilder
    private func terms(for tier: ProTier) -> some View {
        let shortTerms: [ProProduct.Term] = [.monthly, .weekly]
        VStack(spacing: 8) {
            termRow(tier, .yearly)
            termRow(tier, .lifetime)
            if showsShortTerms {
                ForEach(shortTerms, id: \.self) { termRow(tier, $0) }
            } else if shortTerms.contains(where: { purchases.product(productID(tier, $0)) != nil }) {
                Button {
                    withAnimation(.snappy) { showsShortTerms = true }
                } label: {
                    Label("주 · 월 구독도 보기", systemImage: "chevron.down")
                        .font(.body)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            // 연 구독을 아직 못 불러왔으면 고를 수 있는 첫 길로 옮긴다.
            if purchases.product(productID(tier, term(for: tier).wrappedValue)) == nil,
               let first = ProProduct.Term.allCases.first(where: { purchases.product(productID(tier, $0)) != nil }) {
                term(for: tier).wrappedValue = first
            }
        }
    }

    /// 길 하나. 불러온 상품만 그린다 — 스토어에 아직 없는 상품의 단추는 세우지 않는다.
    @ViewBuilder
    private func termRow(_ tier: ProTier, _ value: ProProduct.Term) -> some View {
        if let product = purchases.product(productID(tier, value)) {
            let selected = term(for: tier).wrappedValue == value
            Button {
                term(for: tier).wrappedValue = value
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(value))
                            .font(.body.weight(.semibold))
                        if let note = note(tier, value, product) {
                            Text(note)
                                .font(.body)
                                .foregroundStyle(Color.accentColor)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(price(value, product))
                        .font(.body)
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                }
                .padding(12)
                .frame(minHeight: 44)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(selected ? Color.accentColor.opacity(0.12) : Color(.tertiarySystemFill))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        }
    }

    private func title(_ term: ProProduct.Term) -> String {
        switch term {
        case .yearly:   LeeoLadderText.yearly
        case .lifetime: LeeoLadderText.lifetime
        case .monthly:  String(localized: "월 구독")
        case .weekly:   String(localized: "주 구독")
        }
    }

    private func price(_ term: ProProduct.Term, _ product: Product) -> String {
        switch term {
        case .yearly:   String(format: LeeoLadderText.perYearFormat, product.displayPrice)
        case .lifetime: product.displayPrice
        case .monthly:  String(localized: "\(product.displayPrice) / 월")
        case .weekly:   String(localized: "\(product.displayPrice) / 주")
        }
    }

    /// 연 구독엔 첫 해 값(처음 구독하는 사람만), 평생엔 "연 구독 N년치".
    private func note(_ tier: ProTier, _ term: ProProduct.Term, _ product: Product) -> String? {
        switch term {
        case .yearly:
            guard introEligible.contains(product.id), let offer = product.subscription?.introductoryOffer,
                  offer.paymentMode == .payUpFront || offer.paymentMode == .payAsYouGo else { return nil }
            return String(format: LeeoLadderText.introFormat, offer.displayPrice)
        case .lifetime:
            // 올리기 상품은 이미 Plus 평생을 낸 사람의 차액이라 몇 년치로 말하지 않는다.
            guard product.id != ProProduct.upgrade,
                  let yearly = purchases.product(productID(tier, .yearly))?.price, yearly > 0 else { return nil }
            let years = Int(NSDecimalNumber(decimal: product.price / yearly).doubleValue.rounded(.down))
            return years >= 2 ? String(format: LeeoLadderText.lifetimeWorthFormat, years) : nil
        case .monthly, .weekly:
            return nil
        }
    }

    private func buyButton(_ tier: ProTier) -> some View {
        let chosen = term(for: tier).wrappedValue
        let product = purchases.product(productID(tier, chosen))
        let title: String = switch chosen {
        case .lifetime where product?.id == ProProduct.upgrade: String(localized: "Pro 평생으로 올리기")
        case .lifetime: String(localized: "평생으로 사기")
        case .yearly, .monthly, .weekly: String(localized: "구독하기")
        }
        return Button {
            guard let product else { return }
            Task {
                await purchases.purchase(product, using: purchaseAction)
                if purchases.tier >= tier { dismiss() }
            }
        } label: {
            Group {
                if purchases.isWorking {
                    ProgressView().tint(.white)
                } else {
                    Text(title).font(.headline)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(purchases.isWorking || product == nil)
    }

    // MARK: 요금제를 못 불러왔을 때

    @ViewBuilder
    private var plansStatus: some View {
        if purchases.products.isEmpty && loadingProducts {
            HStack(spacing: 10) {
                ProgressView()
                Text("값을 불러오는 중…")
                    .font(.body)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        } else if purchases.products.isEmpty {
            // 한 번 실패하면 영영 죽은 단추로 남지 않게, 그 자리에서 다시 청한다.
            VStack(alignment: .leading, spacing: 10) {
                Text("요금제를 불러오지 못했어요. 인터넷 연결을 확인하고 다시 불러와 주세요.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    Task { await loadPlans() }
                } label: {
                    Label("다시 불러오기", systemImage: "arrow.clockwise")
                        .font(.body.weight(.semibold))
                }
                .buttonStyle(.bordered)
            }
        }
    }

    /// 첫 조회가 비어 오면 한 번 더 청한다. 샌드박스(심사 환경)는 첫 조회가 빈손으로 돌아오는 일이 잦다.
    private func loadPlans() async {
        loadingProducts = true
        await purchases.loadProducts()
        if purchases.products.isEmpty {
            try? await Task.sleep(for: .seconds(1.5))
            await purchases.loadProducts()
        }
        loadingProducts = false
    }

    private func checkIntroEligibility() async {
        var eligible: Set<String> = []
        for id in [ProProduct.plusYearly, ProProduct.proYearly] {
            if let subscription = purchases.product(id)?.subscription, await subscription.isEligibleForIntroOffer {
                eligible.insert(id)
            }
        }
        introEligible = eligible
    }

    // MARK: 약관 (구독을 파는 앱의 심사 필수 항목)

    private var legal: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("구독은 기간이 끝나기 24시간 전까지 해지하지 않으면 같은 요금으로 자동 갱신되며, Apple 계정으로 결제돼요. 해지와 관리는 App Store 계정 설정에서 해요. 평생은 구독이 아니라 한 번 결제예요.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits {
                HStack(spacing: 18) { legalLinks }
                VStack(alignment: .leading, spacing: 10) { legalLinks }
            }
            .font(.body)
        }
    }

    @ViewBuilder
    private var legalLinks: some View {
        if let terms = SlideSnapSpec.monetization.subscriptionTermsURL {
            Button("이용약관") { openURL(terms) }
        }
        Button("개인정보 처리방침") { openURL(SlideSnapSpec.legal.privacyURL) }
    }
}

// MARK: - 비교표

/// 무료 · Plus · Pro 가 무엇을 여는지 한 장에. 무료로 되는 줄부터 위에 둔다.
struct PlanComparisonTable: View {
    var highlight: ProFeature?

    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var columnWidth: CGFloat = 62

    private enum Cell {
        case yes, no, unlimited
        case count(Int)
    }

    private struct Row: Identifiable {
        let title: String
        var feature: ProFeature?
        let free: Cell, plus: Cell, pro: Cell
        var id: String { title }
    }

    private var rows: [Row] {
        [
            Row(title: String(localized: "원근 보정 · 무음 · 자동 촬영"), free: .yes, plus: .yes, pro: .yes),
            Row(title: String(localized: "글자 인식 · 검색"), free: .yes, plus: .yes, pro: .yes),
            Row(title: String(localized: "사진 앱 가져오기 · 공유 확장 · 위젯"), free: .yes, plus: .yes, pro: .yes),
            Row(title: String(localized: "이미지 공유 · PDF 한 장씩"), free: .yes, plus: .yes, pro: .yes),
            Row(title: String(localized: "발표"), feature: .unlimitedPresentations,
                free: .count(FreeLimit.presentations), plus: .unlimited, pro: .unlimited),
            Row(title: String(localized: "또렷하게 보정"), feature: .enhance, free: .no, plus: .yes, pro: .yes),
            Row(title: String(localized: "PDF 두 장 · 네 장씩"), feature: .pdfLayouts, free: .no, plus: .yes, pro: .yes),
            Row(title: String(localized: "녹음 · 받아쓰기"), feature: .recording, free: .no, plus: .no, pro: .yes),
            Row(title: String(localized: "기기 안 요약"), feature: .summary, free: .no, plus: .no, pro: .yes),
            Row(title: String(localized: "PowerPoint · Markdown 내보내기"), feature: .notesExport, free: .no, plus: .no, pro: .yes),
            Row(title: String(localized: "iCloud 동기화"), feature: .sync, free: .no, plus: .no, pro: .yes),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                columnHeader(ProTier.free.title)
                columnHeader("Plus")
                columnHeader("Pro")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .accessibilityHidden(true)

            ForEach(rows) { row in
                rowView(row)
                if row.id != rows.last?.id { Divider().padding(.leading, 12) }
            }
        }
        .padding(.vertical, 4)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func columnHeader(_ title: String) -> some View {
        Text(title)
            .font(.body.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: columnWidth)
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        let highlighted = row.feature != nil && row.feature == highlight
        let values = HStack(spacing: 0) {
            cell(row.free)
            cell(row.plus)
            cell(row.pro)
        }
        Group {
            // 아주 큰 글자에서는 이름을 위에, 값을 아래에 둔다. 나란히 두면 이름이 몇 줄로 꺾인다.
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    Text(row.title).font(.body)
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        values
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Text(row.title)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    values
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(highlighted ? Color.accentColor.opacity(0.12) : .clear)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.title)
        .accessibilityValue(Text(verbatim: "\(ProTier.free.title): \(spoken(row.free)), Plus: \(spoken(row.plus)), Pro: \(spoken(row.pro))"))
    }

    @ViewBuilder
    private func cell(_ value: Cell) -> some View {
        Group {
            switch value {
            case .yes:
                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
            case .no:
                Text(verbatim: "–").foregroundStyle(.tertiary)
            case .unlimited:
                Image(systemName: "infinity").foregroundStyle(Color.accentColor)
            case .count(let n):
                Text(n, format: .number).monospacedDigit()
            }
        }
        .font(.body.weight(.semibold))
        .frame(width: columnWidth)
    }

    private func spoken(_ value: Cell) -> String {
        switch value {
        case .yes:          String(localized: "포함")
        case .no:           String(localized: "없음")
        case .unlimited:    String(localized: "무제한")
        case .count(let n): n.formatted()
        }
    }
}

// MARK: - 잠긴 자리

/// 잠긴 메뉴 · 단추의 아이콘. 눌러 보기 전에 잠긴 걸 알 수 있어야 한다.
extension ProFeature {
    /// 쓸 수 있으면 원래 아이콘, 잠겼으면 자물쇠.
    @MainActor
    func icon(_ unlocked: String) -> String {
        PurchaseManager.shared.allows(self) ? unlocked : "lock.fill"
    }
}

extension View {
    /// `feature` 가 들어 있으면 그 기능의 페이월을 낸다.
    func paywall(for feature: Binding<ProFeature?>) -> some View {
        sheet(item: feature) { PaywallView(highlight: $0) }
    }
}
