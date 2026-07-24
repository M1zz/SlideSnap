import SwiftUI
import LeeoKit

@main
struct SlideSnapApp: App {
    @StateObject private var store = Store()
    @StateObject private var profile = UserProfileStore()
    @StateObject private var feedbackPrompt = FeedbackPromptManager()
    @StateObject private var router = AppRouter()

    var body: some Scene {
        WindowGroup {
            PresentationListView()
                .environmentObject(store)
                .environmentObject(profile)
                .environmentObject(feedbackPrompt)
                .environmentObject(router)
                .onOpenURL { url in
                    router.handle(url)
                }
                .onAppear {
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
        }
        // 새 피드백 로컬 알림: iOS가 앱을 백그라운드에서 깨우면 새 피드백을 확인해
        // 로컬 알림을 발송하고, 다음 새로고침을 다시 예약한다(알림 켜진 경우에만).
        .backgroundTask(.appRefresh(LeeoFeedbackService.backgroundRefreshTaskIdentifier)) {
            let feedback = LeeoFeedbackService(spec: SlideSnapSpec.self)
            await feedback.checkForNewFeedbackAndNotify()
            feedback.scheduleBackgroundRefresh()
        }
    }
}
