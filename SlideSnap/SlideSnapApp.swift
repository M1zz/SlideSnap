import SwiftUI
import LeeoKit

@main
struct SlideSnapApp: App {
    @StateObject private var store = Store()
    @StateObject private var feedbackPrompt = FeedbackPromptManager()
    @StateObject private var router = AppRouter.shared
    @StateObject private var cloudSync = CloudSync()
    @StateObject private var purchases = PurchaseManager.shared
    /// 구독 중인 사람에게 6개월째 · 갱신 7일 전에 한 번씩 보이는 '구독 졸업' (→ LeeoGraduation).
    @State private var showingGraduation = false
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // 백업 금고: 예약된 복원 · 업데이트 직전 백업을 저장소가 열리기 전에 한다
        LeeoVault.start(SlideSnapSpec.self)
    }

    var body: some Scene {
        WindowGroup {
            PresentationListView()
                // 개발자가 보낸 의견에 답장하면, 앱이 앞으로 올 때 답장을 시트로 보여 준다 (LeeoKit).
                .leeoFeedbackReplyNotice(SlideSnapSpec.self)
                // 아이폰 듀오: 접힘을 재서 아래로 흘리고, 시트 · 알림창이 접힌 선을 비키게 한다.
                .foldAware()
                #if DEBUG
                // `-reviewShot <상품 ID>` 면 앱 대신 그 상품의 심사 이미지 장면을 세운다 (→ ReviewShot.swift).
                .reviewShotScene()
                #endif
                .environmentObject(store)
                .environmentObject(feedbackPrompt)
                .environmentObject(router)
                .environmentObject(cloudSync)
                .environmentObject(purchases)
                .onOpenURL { url in
                    router.handle(url)
                }
                .task { await refreshPlan() }
                .sheet(isPresented: $showingGraduation) {
                    LeeoGraduationOfferView(graduate: purchases.product(ProProduct.graduate)) {
                        await purchases.refresh()
                    }
                    .presentationDetents([.medium, .large])
                }
                // Spotlight 에 싣는 장표를 지금 것에 맞춘다 (→ SlideIntents.swift)
                .task { await SlideLibrary.reindex() }
                .onAppear {
                    cloudSync.attach(store)
                    if cloudSync.isEnabled { UIApplication.shared.registerForRemoteNotifications() }
                    // 마스터 모드(개발자): 새 피드백 로컬 알림이 켜져 있으면 앱을 열 때 즉시
                    // 새 피드백을 확인하고(포그라운드 보완), 다음 백그라운드 새로고침을 예약한다.
                    let feedback = LeeoFeedbackService(spec: SlideSnapSpec.self)
                    if feedback.isLocalNotifyEnabled {
                        feedback.scheduleBackgroundRefresh()
                        Task { await feedback.checkForNewFeedbackAndNotify() }
                    }
                    // 익명 사용 통계 — 실행 카운트 + FeedbackHub로 설치 스냅샷 전송(하루 1회 throttle).
                    // 앱 대략 지표(발표 수·장표 수)도 함께 담는다.
                    LeeoEngagement.shared.registerLaunch()
                    let slideCount = store.presentations.reduce(0) { $0 + $1.slides.count }
                    LeeoUsageReporter(spec: SlideSnapSpec.self).reportInBackground(metrics: [
                        "presentations": Double(store.presentations.count),
                        "slides": Double(slideCount)
                    ])
                }
                .onChange(of: scenePhase) { _, phase in
                    // 앱을 다시 열 때 다른 기기에서 바뀐 내용을 가져온다.
                    if phase == .active {
                        Task {
                            await refreshPlan()
                            await cloudSync.syncNow()
                        }
                    }
                }
        }
        // 새 피드백 로컬 알림: iOS가 앱을 백그라운드에서 깨우면 새 피드백을 확인해
        // 로컬 알림을 발송하고, 다음 새로고침을 다시 예약한다(알림 켜진 경우에만).
        .backgroundTask(.appRefresh(LeeoFeedbackService.backgroundRefreshTaskIdentifier)) {
            let feedback = LeeoFeedbackService(spec: SlideSnapSpec.self)
            await feedback.checkForNewFeedbackAndNotify()
            feedback.scheduleBackgroundRefresh()
        }
    }

    /// 영수증을 다시 읽고, 칸에 맞춰 iCloud 동기화를 멈추거나 구독 졸업을 제안한다.
    private func refreshPlan() async {
        await purchases.refresh()
        // 구독이 끝났으면 동기화를 멈춘다. 이 기기의 발표 · 장표 · 녹음은 그대로 남는다.
        if cloudSync.isEnabled, !purchases.allows(.sync) { cloudSync.disable() }
        if purchases.graduationIsDue, !showingGraduation {
            purchases.markGraduationOffered()
            showingGraduation = true
        }
    }
}
