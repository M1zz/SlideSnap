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
        }
    }
}
