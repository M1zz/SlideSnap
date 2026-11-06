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
//    -SSDemoScreen slide:<n>       첫 발표의 n번째(0부터) 장표 크게 보기
//    -SSDemoScreen notes           첫 발표의 발표 노트(AI 요약·녹음)
//    -SSDemoScreen search:<검색어>  장표 글자 검색 결과
//    -SSDemoScreen share           공유 익스텐션 화면 (App Group의 DemoShare/ 사진으로)
//    -SSDemoScreen paywall         요금제(무료 발표를 다 채운 자리에서 연 페이월)
//    -SSDemoMemo<n> <메모>         첫 발표의 n번째(0부터) 장표에 메모를 단다 (어느 화면과도 함께)
//    -SSDemoNotes <base64 JSON>    첫 발표에 데모 녹음을 붙이고, 있으면 받아쓴 말·AI 요약도 넣는다
//                                  {"summary":{"overview":…,"points":[…],"keywords":[…]}, "spoken":{"1":"…"}}
//
//  scripts/make_screenshots.sh 가 이 인자로 화면을 하나씩 띄워 찍는다.
//

#if DEBUG
import Foundation

enum DemoMode {
    enum Screen: Equatable {
        case list, detail, slide(Int), notes, search(String), share, paywall
    }

    static var screen: Screen? {
        guard let raw = UserDefaults.standard.string(forKey: "SSDemoScreen") else { return nil }
        switch raw {
        case "list": return .list
        case "detail": return .detail
        case "slide": return .slide(1)
        case "notes": return .notes
        case "share": return .share
        case "paywall": return .paywall
        default:
            if raw.hasPrefix("search:") { return .search(String(raw.dropFirst("search:".count))) }
            if raw.hasPrefix("slide:"), let index = Int(raw.dropFirst("slide:".count)) { return .slide(index) }
            return nil
        }
    }

    /// 첫 발표의 장표 번호(0부터) → 데모 메모.
    static var memos: [Int: String] {
        var result: [Int: String] = [:]
        for index in 0..<20 {
            if let memo = UserDefaults.standard.string(forKey: "SSDemoMemo\(index)") { result[index] = memo }
        }
        return result
    }

    /// 발표 노트 데모: 녹음 하나와, 있으면 장표별로 받아쓴 말(장표 번호 0부터)과 AI 요약.
    struct Notes: Decodable {
        struct Summary: Decodable { var overview: String; var points: [String]; var keywords: [String] }
        var summary: Summary?
        var spoken: [String: String]?
    }

    static var notes: Notes? {
        // 실행 인자 값은 plist 로 해석되어 JSON 이 깨지므로 base64 로 받는다.
        guard let raw = UserDefaults.standard.string(forKey: "SSDemoNotes"),
              let data = Data(base64Encoded: raw) else { return nil }
        return try? JSONDecoder().decode(Notes.self, from: data)
    }

    /// 실행할 때마다 녹음이 늘지 않게 늘 같은 id 를 쓴다.
    static let recordingID = UUID(uuidString: "00000000-0000-0000-0000-00000000DE70")!

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
