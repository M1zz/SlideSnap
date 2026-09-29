//
//  DemoMode.swift
//  SlideSnap
//
//  앱스토어 스크린샷용 데모 모드 (DEBUG 빌드 전용 — 출시 빌드에는 들어가지 않는다).
//  시뮬레이터는 카메라도 탭 자동화도 없으므로, 실행 인자로 보여 줄 화면을 바로 정한다.
//
//    -SSDemoScreen list            발표 목록(그리드)
//    -SSDemoScreen detail          첫 발표의 장표 그리드
//    -SSDemoScreen slide           첫 발표의 둘째 장표 크게 보기
//    -SSDemoScreen search:<검색어>  장표 글자 검색 결과
//    -SSDemoScreen share           공유 익스텐션 화면 (App Group의 DemoShare/ 사진으로)
//
//  scripts/make_screenshots.sh 가 이 인자로 화면을 하나씩 띄워 찍는다.
//

#if DEBUG
import Foundation

enum DemoMode {
    enum Screen: Equatable {
        case list, detail, slide, search(String), share
    }

    static var screen: Screen? {
        guard let raw = UserDefaults.standard.string(forKey: "SSDemoScreen") else { return nil }
        switch raw {
        case "list": return .list
        case "detail": return .detail
        case "slide": return .slide
        case "share": return .share
        default:
            if raw.hasPrefix("search:") { return .search(String(raw.dropFirst("search:".count))) }
            return nil
        }
    }

    /// 공유 화면 데모에 쓸 사진들(이름순).
    static var shareDemoPhotos: [URL] {
        guard let dir = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: ShareInbox.appGroupID)?
            .appendingPathComponent("DemoShare", isDirectory: true),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
#endif
