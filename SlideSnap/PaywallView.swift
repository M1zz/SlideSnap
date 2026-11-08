//
//  PaywallView.swift
//  SlideSnap
//
//  장표스냅의 세 칸(무료 · Plus · Pro)을 파는 한 장. 클립키보드와 같은 그림 틀이다(LeeoKit `LeeoShowcasePaywall`):
//  위에 고른 칸의 기능 그림(옆으로 넘긴다), 고를 Plus · Pro 칸 카드(칸마다 연 구독 · 평생, 펼치면 월),
//  그 아래 무료 칸, 늘 떠 있는 구매 단추 하나, 스크롤한 아래에 구독 고지 · 약관 · 코드 사용 · 비교표.
//
//  **무료로 남는 것도 말한다.** 이 화면을 닫고 나서도 사는 사람도 안 사는 사람도 앱을 계속 쓴다.
//  첫 해 할인(App Store 첫 구독 할인)과 "연 구독 N년치" 한 줄은 `LeeoTermPicker` 가 알아서 보인다.
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
    /// 설정의 요금제 줄에서 **화면으로 넘어와** 열렸다 — 바깥 내비게이션을 쓰고 닫기 단추를 두지 않는다.
    var embedded = false

    @ObservedObject private var purchases = PurchaseManager.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.leeoStyle) private var theme
    /// 결제 시트를 **이 페이월이 떠 있는 창**에 띄운다 (→ PurchaseManager.purchase).
    @Environment(\.purchase) private var purchaseAction

    /// 고른 칸. 없으면 들어온 자리의 칸, 그것도 없으면 살 수 있는 첫 칸.
    @State private var chosenTier: ProTier?
    /// 칸마다 고른 연 구독 / 평생. 처음엔 연 구독.
    @State private var terms: [ProTier: LeeoPlanTerm] = [:]
    /// 펼쳐서 고른 월 구독. 고르면 연 / 평생보다 먼저다.
    @State private var shortTerms: [ProTier: ProProduct.Term] = [:]
    /// 월 구독을 펼쳤는가.
    @State private var showsShortTerms = false
    @State private var loadingProducts = true
    /// App Store 의 코드 사용 시트(오퍼 코드 · 선물받은 코드).
    @State private var redeemingCode = false

    var body: some View {
        Group {
            if embedded {
                page
            } else {
                NavigationStack {
                    page.toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("닫기", systemImage: "xmark") { dismiss() }
                        }
                    }
                }
            }
        }
        // 코드를 쓴 뒤에는 권한을 다시 읽는다. 칸이 열렸으면 닫는다.
        .offerCodeRedemption(isPresented: $redeemingCode) { _ in
            Task {
                await purchases.refresh()
                closeIfUnlocked()
            }
        }
        .task {
            LeeoAnalyticsCenter.track(.paywallShown(reason: highlight?.rawValue ?? "profile"))
            await loadPlans()
        }
        #if DEBUG
        .onAppear { if let id = ReviewShot.productID { preselect(id) } }
        #endif
    }

    #if DEBUG
    /// 심사 이미지: 그 상품의 칸 · 길을 골라 둔다 (→ ReviewShot.swift).
    private func preselect(_ id: String) {
        guard let tier = ProProduct.tierByProduct[id],
              let term = ProProduct.Term.allCases.first(where: {
                  ProProduct.id(tier, $0, ownsPlusLifetime: purchases.ownsPlusLifetime) == id
              }) else { return }
        chosenTier = tier
        switch term {
        case .yearly:   terms[tier] = .yearly
        case .lifetime: terms[tier] = .lifetime
        case .monthly:
            shortTerms[tier] = term
            showsShortTerms = true
        }
    }
    #endif

    private var page: some View {
        // 고른 칸의 기능 그림을 옆으로 넘겨 보인다. 들어온 자리의 기능이 첫 장이다 (→ PaywallShowcase.swift).
        LeeoShowcasePaywall(showcases: shownTier.showcases(first: highlight)) {
            if let reason { reasonLine(reason) }
        } plans: {
            VStack(spacing: 12) {
                plansStatus
                // 들어온 자리의 칸이 먼저다.
                ForEach(highlight?.tier == .pro ? [ProTier.pro, .plus] : [.plus, .pro], id: \.self) { tierCard($0) }
                freeCard
            }
        } button: {
            if let tier = selectedTier { buyButton(tier) }
        } details: {
            VStack(alignment: .leading, spacing: 20) {
                // 요금제를 못 불러온 것은 `plansStatus` 가 직접 말한다. 여기는 사다가 막힌 이유만.
                if let message = purchases.failureMessage, !purchases.products.isEmpty {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.body)
                        .foregroundStyle(.orange)
                }
                legal
                Button("코드 사용") { redeemingCode = true }
                    .font(.body)
                // 다 가진 사람이 더 내고 싶을 때 갈 곳(응원). 팁 상품이 와 있을 때만 선다.
                if purchases.tier == .pro {
                    LeeoTipJarLink<SlideSnapSpec>(tipJar: purchases.tipJar)
                }
                PlanComparisonTable(highlight: highlight)
            }
        }
        .navigationTitle("요금제")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("구매 복원") {
                    Task {
                        await purchases.restore()
                        closeIfUnlocked()
                    }
                }
                .disabled(purchases.isWorking)
            }
        }
    }

    /// 들어온 자리의 칸이 열렸으면 닫는다(설정에서 넘어왔으면 설정으로 돌아간다).
    private func closeIfUnlocked() {
        if purchases.tier >= (highlight?.tier ?? .plus) { dismiss() }
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

    // MARK: 칸 카드

    /// 무료 칸. 고를 것이 없어 단추도 동그라미도 없다.
    private var freeCard: some View {
        card(selected: false) {
            cardTitle(.free)
            Text("찍고 펴고 묶고 찾는 일은 계속 무료예요.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 유료 칸. 누르면 고른다. 고른 칸에서 길(연 구독 · 평생, 펼치면 월)을 고르고, 사는 것은 떠 있는 단추다.
    private func tierCard(_ tier: ProTier) -> some View {
        let selected = tier == selectedTier
        return card(selected: selected) {
            Button {
                // 이미 이 칸 이상이면 살 것이 없다. 구독을 평생으로 바꾸는 길은 설정에 있다.
                guard purchasable(tier) else { return }
                withAnimation(.snappy) { chosenTier = tier }
            } label: {
                VStack(alignment: .leading, spacing: 10) {
                    cardTitle(tier)
                    Text(tier == .plus ? String(localized: "한 학기, 한 학회를 통째로. 글자는 더 또렷하게.")
                                       : String(localized: "그때 한 말까지 장표 옆에, 요약은 기기가 알아서."))
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            if selected {
                LeeoTermPicker(term: termBinding(tier), yearly: product(tier, .yearly), lifetime: product(tier, .lifetime))
                    .padding(.top, 4)
                shortTermRows(tier)
            }
        }
    }

    private func cardTitle(_ tier: ProTier) -> some View {
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
    }

    /// 칸 카드의 모양. 고른 칸은 테두리가 선다.
    private func card(selected: Bool, @ViewBuilder content: () -> some View) -> some View {
        let shape = RoundedRectangle(cornerRadius: theme.radiusLg, style: .continuous)
        return VStack(alignment: .leading, spacing: 10, content: content)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.bg, in: shape)
            .overlay(shape.strokeBorder(selected ? theme.accent : Color(.separator), lineWidth: selected ? 2 : 1))
    }

    // MARK: 고르기

    /// 살 수 있는 칸 — 지금 칸보다 높고, 상품을 하나라도 불러왔다.
    private func purchasable(_ tier: ProTier) -> Bool {
        purchases.tier < tier && ProProduct.Term.allCases.contains { product(tier, $0) != nil }
    }

    /// 그림을 보일 칸. 고른 칸, 살 것이 없으면(이미 Pro) 지금 칸.
    private var shownTier: ProTier {
        selectedTier ?? max(highlight?.tier ?? .plus, purchases.tier)
    }

    private var selectedTier: ProTier? {
        let candidates = [chosenTier, highlight?.tier, .plus, .pro].compactMap { $0 }
        return candidates.first(where: purchasable)
    }

    private func product(_ tier: ProTier, _ term: ProProduct.Term) -> Product? {
        purchases.product(ProProduct.id(tier, term, ownsPlusLifetime: purchases.ownsPlusLifetime))
    }

    /// 고른 길. 고른 쪽 상품이 없으면(App Store 에 아직 없음) 있는 쪽으로 옮긴다.
    private func term(_ tier: ProTier) -> LeeoPlanTerm {
        switch terms[tier] ?? .yearly {
        case .yearly:   product(tier, .yearly) == nil && product(tier, .lifetime) != nil ? .lifetime : .yearly
        case .lifetime: product(tier, .lifetime) == nil && product(tier, .yearly) != nil ? .yearly : .lifetime
        }
    }

    /// 월을 고르면 연 / 평생 고르기는 연 구독 자리에 둔다. 연 / 평생을 누르면 월 고른 것이 풀린다.
    private func termBinding(_ tier: ProTier) -> Binding<LeeoPlanTerm> {
        Binding(get: { shortTerms[tier] == nil ? term(tier) : .yearly },
                set: { terms[tier] = $0; shortTerms[tier] = nil })
    }

    private func selectedProduct(_ tier: ProTier) -> Product? {
        if let short = shortTerms[tier] { return product(tier, short) }
        return product(tier, term(tier) == .yearly ? .yearly : .lifetime)
    }

    /// 월 구독. 연 구독이 기본이라 펼쳐야 보인다. 상품이 없으면 줄이 서지 않는다.
    @ViewBuilder
    private func shortTermRows(_ tier: ProTier) -> some View {
        let available = [ProProduct.Term.monthly].compactMap { term in product(tier, term).map { (term, $0) } }
        if showsShortTerms {
            ForEach(available, id: \.0) { term, product in
                shortTermRow(tier, term, product)
            }
        } else if !available.isEmpty {
            Button {
                withAnimation(.snappy) { showsShortTerms = true }
            } label: {
                Label("월 구독도 보기", systemImage: "chevron.down")
                    .font(.body)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .foregroundStyle(.secondary)
        }
    }

    private func shortTermRow(_ tier: ProTier, _ term: ProProduct.Term, _ product: Product) -> some View {
        let selected = shortTerms[tier] == term
        return Button {
            shortTerms[tier] = selected ? nil : term
        } label: {
            HStack {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .accessibilityHidden(true)
                Text("월 구독")
                Spacer()
                Text(term == .monthly ? String(localized: "\(product.displayPrice) / 월")
                                      : String(localized: "\(product.displayPrice) / 주"))
                    .monospacedDigit()
            }
            .font(.body)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: 사는 단추 (늘 떠 있다)

    private func buyButton(_ tier: ProTier) -> some View {
        let product = selectedProduct(tier)
        let title: String = if product?.subscription != nil {
            String(localized: "구독하기")
        } else if product?.id == ProProduct.upgrade {
            String(localized: "Pro 평생으로 올리기")
        } else {
            String(localized: "평생으로 사기")
        }
        return LeeoPrimaryButton(title: title, isWorking: purchases.isWorking) {
            guard let product else { return }
            Task {
                await purchases.purchase(product, using: purchaseAction)
                if purchases.tier >= tier { dismiss() }
            }
        }
        .disabled(product == nil)
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
            .frame(maxWidth: .infinity, alignment: .leading)
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

    // MARK: 구독 고지 · 약관 (구독을 파는 앱의 심사 필수 항목)

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
        .background(Color(.secondarySystemBackground),
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
