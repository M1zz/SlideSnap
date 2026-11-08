//
//  SettingsView.swift
//  SlideSnap
//
//  설정 — 요금제와 응원 · 발표 동기화 · 앱 정보.
//  피드백 회신용 이름 · 이메일은 피드백 화면이 직접 받고 기억한다(LeeoKit).
//

import SwiftUI
import LeeoKit

struct SettingsView: View {
    @EnvironmentObject private var cloudSync: CloudSync
    @ObservedObject private var purchases = PurchaseManager.shared
    @State private var paywallFeature: ProFeature?
    @State private var showingManageSubscription = false
    /// 구독 중인 사람이 평생으로 옮겨 가는 시트 (→ LeeoGraduation).
    @State private var showingGraduation = false
    /// 구매 복원을 눌렀는데 찾지 못했을 때 그 까닭.
    @State private var restoreMessage: String?
    @State private var enablingSync = false
    @Environment(\.dismiss) private var dismiss

    /// 마스터(개발자) 모드 — 버전 행 7번 탭으로 토글. 피드백 수신함 진입점 노출.
    @AppStorage("dev.masterMode") private var masterModeEnabled = false
    @State private var versionTapCount = 0
    @State private var showMasterModeAlert = false

    var body: some View {
        NavigationStack {
            Form {
                planSection

                Section {
                    Toggle(isOn: syncBinding) {
                        Label("iCloud 동기화", systemImage: "arrow.triangle.2.circlepath.icloud")
                    }
                    .disabled(enablingSync)
                    if cloudSync.isEnabled {
                        Button {
                            Task { await cloudSync.syncNow() }
                        } label: {
                            HStack {
                                Text("지금 동기화")
                                Spacer()
                                if cloudSync.isSyncing || enablingSync { ProgressView() }
                            }
                        }
                        .disabled(cloudSync.isSyncing)
                    }
                } header: {
                    Text("발표 동기화")
                } footer: {
                    syncFooter
                }

                Section("앱 정보") {
                    // 앞으로 만들 기능 — 원본은 SlideSnapRoadmap.swift
                    NavigationLink(LeeoRoadmapText.entry) { RoadmapScreen() }
                    LeeoShareAppLink<SlideSnapSpec>()
                    NavigationLink { LeeoVaultView(appName: SlideSnapSpec.displayName) } label: {
                        Label(LeeoVaultText.entry, systemImage: "externaldrive.badge.timemachine")
                    }
                    LabeledContent("버전", value: AppInfo.appVersion)
                        .contentShape(Rectangle())
                        .onTapGesture { handleVersionTap() }
                }

                if masterModeEnabled {
                    Section("개발자") {
                        NavigationLink {
                            FeedbackInboxView()
                        } label: {
                            Label("접수된 피드백", systemImage: "tray.full")
                        }
                        NavigationLink {
                            LeeoUsageStatsView<SlideSnapSpec>()
                        } label: {
                            Label("사용 통계", systemImage: "chart.bar.xaxis")
                        }
                    }
                }
            }
            .navigationTitle("설정")
            .paywall(for: $paywallFeature)
            .manageSubscriptionsSheet(isPresented: $showingManageSubscription)
            .sheet(isPresented: $showingGraduation) {
                LeeoGraduationOfferView(graduate: purchases.product(ProProduct.graduate)) {
                    await purchases.refresh()
                }
                .presentationDetents([.medium, .large])
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기", systemImage: "xmark") { dismiss() }
                }
            }
            .alert(
                masterModeEnabled ? String(localized: "개발자 모드가 켜졌어요") : String(localized: "개발자 모드가 꺼졌어요"),
                isPresented: $showMasterModeAlert
            ) {
                Button("확인", role: .cancel) {}
            } message: {
                if masterModeEnabled {
                    Text("아래에 '접수된 피드백' 메뉴가 나타납니다.")
                }
            }
        }
    }

    private var syncBinding: Binding<Bool> {
        Binding(
            get: { cloudSync.isEnabled },
            set: { on in
                if on {
                    // iCloud 동기화는 Pro 기능이다. 끄는 것은 늘 된다(이 기기의 발표는 그대로 남는다).
                    guard purchases.allows(.sync) else {
                        paywallFeature = .sync
                        return
                    }
                    enablingSync = true
                    Task {
                        await cloudSync.enable()
                        if cloudSync.isEnabled { UIApplication.shared.registerForRemoteNotifications() }
                        enablingSync = false
                    }
                } else {
                    cloudSync.disable()
                }
            }
        )
    }

    /// 요금제와 응원 — 돈 이야기는 여기 한 칸에 모은다(두번알림 · 클립키보드와 같다).
    /// 요금제 → (구독 관리 · 평생으로 바꾸기) → 응원 → 선물하기 → 구매 복원.
    private var planSection: some View {
        Section {
            // 설정의 다른 줄처럼 화면으로 넘어간다.
            NavigationLink {
                PaywallView(embedded: true)
            } label: {
                LabeledContent("장표스냅 Plus · Pro") {
                    if purchases.isKnown { Text(purchases.tier.title) }
                }
            }
            if purchases.subscription != nil {
                Button(LeeoLadderText.manageSubscription) { showingManageSubscription = true }
                // 구독 중인 사람이 언제든 평생으로 옮겨 갈 수 있는 길. 졸업가 상품을 못 불러왔으면 세우지 않는다.
                if purchases.product(ProProduct.graduate) != nil {
                    Button(LeeoLadderText.switchToLifetimeEntry) { showingGraduation = true }
                }
            }
            // 응원 — 낸 사람에게는 후원 단계 배지(LeeoSupporterBadge)가 선다. 팁 상품이 App Store 에서 와야 줄이 선다.
            LeeoTipJarLink<SlideSnapSpec>(tipJar: SlideSnapTip.tipJar)
            if SettingsGiftView.hasContent(purchases) {
                NavigationLink {
                    SettingsGiftView()
                } label: {
                    Label("선물하기", systemImage: "gift.fill")
                }
            }
            Button {
                Task {
                    await purchases.restore()
                    restoreMessage = purchases.tier == .free ? purchases.failureMessage : nil
                }
            } label: {
                HStack {
                    Text("구매 복원")
                    Spacer()
                    if purchases.isWorking { ProgressView() }
                }
            }
            .disabled(purchases.isWorking)
        } header: {
            Text("요금제와 응원")
        } footer: {
            if purchases.isGrandfathered {
                Text("유료 앱일 때 장표스냅을 사 주셔서 Pro를 평생 그대로 써요. 고맙습니다.")
            } else if let restoreMessage {
                Text(restoreMessage)
            }
        }
    }

    @ViewBuilder
    private var syncFooter: some View {
        if let error = cloudSync.lastError {
            Text(error).foregroundStyle(.red)
        } else if cloudSync.isEnabled, let last = cloudSync.lastSyncedAt {
            Text("마지막 동기화: \(last.formatted(.relative(presentation: .named)))")
        } else {
            Text("같은 Apple ID로 로그인한 iPhone·iPad·Mac에서 발표·장표·녹음을 함께 봐요. 사진과 녹음이 iCloud 저장 공간을 사용해요.")
        }
    }

    /// 버전 행 7번 탭 → 마스터(개발자) 모드 토글.
    private func handleVersionTap() {
        versionTapCount += 1
        guard versionTapCount >= 7 else { return }
        versionTapCount = 0
        masterModeEnabled.toggle()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        showMasterModeAlert = true
    }

}

/// 설정 ▸ 선물하기. 누르면 바로 칸(Plus · Pro)을 고르고 선물하는 한 화면이다(LeeoKit `LeeoGiftPickerView`).
/// 선물을 사면 App Store 오퍼 코드 링크가 나오고, 받은 사람은 App Store 에서 "사용" 한 번으로 열린다 —
/// 여는 것은 우리 코드가 아니라 App Store 다(지침 3.1.1).
/// ⚠️ 문구는 LeeoKit 카탈로그에 있다(`LeeoGiftText`) — 앱 카탈로그에 다시 적지 않는다.
struct SettingsGiftView: View {
    @ObservedObject private var purchases = PurchaseManager.shared
    /// 선물이 안 될 때의 문의 창(결제 번호 · 코드가 붙는다).
    @State private var showSupport = false

    /// 보낼 수 있는 선물, 싼 것(Plus)부터. 상품이 App Store 에서 왔거나 이미 보낸 · 준비 중인 결제가 있으면 선다.
    private static func senders(_ purchases: PurchaseManager) -> [LeeoGiftStore] {
        purchases.gifts.filter { $0.isAvailable || $0.pendingCount > 0 || !$0.sentGifts.isEmpty }.reversed()
    }

    /// 설정에 선물 줄을 세울지. 상품이 App Store 에 서기 전에 이 빌드가 나가도 빈 줄은 보이지 않는다.
    static func hasContent(_ purchases: PurchaseManager) -> Bool {
        !senders(purchases).isEmpty
    }

    var body: some View {
        // 받기 링크는 아직 Pro 가 아닌 사람에게만 — 링크 없이 코드만 받은 사람을 위한 자리다.
        LeeoGiftPickerView<SlideSnapSpec>(gifts: Self.senders(purchases),
                                          showsRedeemLink: purchases.tier < .pro,
                                          onContactSupport: { showSupport = true })
            .sheet(isPresented: $showSupport) {
                LeeoFeedbackView<SlideSnapSpec>(initialType: .bug,
                                                extraInfo: purchases.gifts.flatMap(\.supportLines),
                                                initialCategory: .purchase)
            }
    }
}
