import SwiftUI

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
                    // 마스터 모드(개발자): 새 피드백 푸시 구독을 위해 APNs 재등록.
                    // 프롬프트 없이 조용히 동작 — 알림 권한은 수신함 토글에서 요청한다.
                    if UserDefaults.standard.bool(forKey: "dev.masterMode") {
                        UIApplication.shared.registerForRemoteNotifications()
                    }
                }
        }
    }
}
