//
//  AppRouter.swift
//  SlideSnap
//
//  홈 화면 위젯 등 앱 밖에서 들어오는 딥링크(slidesnap://camera)를 화면 동작으로 잇는다.
//

import SwiftUI

@MainActor
final class AppRouter: ObservableObject {
    /// 카메라 즉시 실행 요청. 값이 바뀔 때마다 목록 화면이 카메라를 연다.
    @Published var cameraLaunchRequest = 0

    /// 들어온 URL을 해석해 라우팅한다. 처리하면 true.
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard url.scheme == "slidesnap" else { return false }
        // slidesnap://camera 또는 host 없이 path가 camera인 경우 모두 카메라로.
        if url.host == "camera" || url.path.contains("camera") {
            cameraLaunchRequest &+= 1
            return true
        }
        return false
    }
}
