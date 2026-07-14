import SwiftUI

@main
struct SlideSnapApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        WindowGroup {
            PresentationListView()
                .environmentObject(store)
        }
    }
}
