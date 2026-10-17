//
//  SlideSnapRoadmap.swift
//  SlideSnap
//
//  **앞으로 만들 것**의 원본. 내 정보 ▸ 앞으로 만들 기능(`LeeoRoadmapView`)이 이 목록을 그대로 보여 준다.
//
//  ⚠️ 개발하다 "이건 다음에" 가 생기면 **여기에 한 줄을 더한다.** 코드의 TODO 주석으로만 남기지 않는다.
//     - 새 항목: `.planned`. 손대기 시작하면 `.building`. 내보내면 `.shipped("1.2.0")`.
//     - id 는 한 번 정하면 바꾸지 않는다(문구는 바꿔도 된다). 다른 앱과 같은 피처는 같은 id 를 쓴다.
//     - 문구는 사용자 말로 쓴다(내부 이름 · 기술 용어 금지). 번역은 `Localizable.xcstrings` 에 영어까지 채운다.
//     - 사용자에게 보일 만한 것만 적는다. 리팩터링 · 시험 · 빌드 설정은 `.sprintcommander/tasks.json` 의 몫이다.
//

import SwiftUI
import LeeoKit

extension SlideSnapSpec {
    static var roadmap: [LeeoRoadmapItem] {[
        // MARK: 다음에 만들어요
        .init(id: "a11y.voiceover", status: .planned,
              title: String(localized: "VoiceOver로 더 편하게", comment: "Roadmap item: VoiceOver"),
              detail: String(localized: "화면 읽기 기능이 단추와 내용을 빠짐없이, 알맞은 순서로 읽어 줘요.", comment: "Roadmap item detail: VoiceOver")),
        .init(id: "a11y.largetext", status: .planned,
              title: String(localized: "큰 글씨에 맞춘 화면", comment: "Roadmap item: larger text layouts"),
              detail: String(localized: "글자 크기를 키워도 잘리지 않고 보기 좋게 다시 배치돼요.", comment: "Roadmap item detail: larger text layouts")),
        .init(id: "display.dark", status: .planned,
              title: String(localized: "다크 모드", comment: "Roadmap item: dark mode"),
              detail: String(localized: "어두운 화면에서도 글자와 단추가 또렷하게 보여요.", comment: "Roadmap item detail: dark mode")),
        .init(id: "a11y.contrast", status: .planned,
              title: String(localized: "보기 편한 색과 대비", comment: "Roadmap item: colors and contrast"),
              detail: String(localized: "대비를 높이거나 색을 구별하기 어려워도 내용을 알아볼 수 있어요.", comment: "Roadmap item detail: colors and contrast")),
        .init(id: "a11y.motion", status: .planned,
              title: String(localized: "움직임 줄이기", comment: "Roadmap item: reduce motion"),
              detail: String(localized: "움직임 줄이기를 켜면 화면 효과가 차분해져요.", comment: "Roadmap item detail: reduce motion")),
        .init(id: "a11y.keyboard", status: .planned,
              title: String(localized: "키보드로 조작하기", comment: "Roadmap item: keyboard control"),
              detail: String(localized: "아이패드에서 키보드만으로 주요 기능을 쓸 수 있어요.", comment: "Roadmap item detail: keyboard control")),
        .init(id: "lang.more", status: .planned,
              title: String(localized: "더 많은 언어", comment: "Roadmap item: more languages"),
              detail: String(localized: "더 많은 나라 말로 앱을 쓸 수 있게 해요.", comment: "Roadmap item detail: more languages")),
        .init(id: "onboarding", status: .planned,
              title: String(localized: "처음 쓰는 분을 위한 안내", comment: "Roadmap item: first-run guide"),
              detail: String(localized: "처음 열었을 때 무엇을 할 수 있는지 짧게 보여 줘요.", comment: "Roadmap item detail: first-run guide")),
        .init(id: "whatsnew", status: .planned,
              title: String(localized: "업데이트 소식", comment: "Roadmap item: what's new after an update"),
              detail: String(localized: "업데이트 뒤 처음 열 때 무엇이 새로 생겼는지 알려 줘요.", comment: "Roadmap item detail: what's new after an update")),
        .init(id: "tips", status: .planned,
              title: String(localized: "쓰는 요령 알려 주기", comment: "Roadmap item: tips"),
              detail: String(localized: "알아 두면 편한 기능을 알맞은 때에 살짝 알려 줘요.", comment: "Roadmap item detail: tips")),
        .init(id: "shortcuts", status: .planned,
              title: String(localized: "Siri와 단축어", comment: "Roadmap item: Siri and Shortcuts"),
              detail: String(localized: "Siri에게 말하거나 단축어로 바로 장표를 찍어요.", comment: "Roadmap item detail: Siri and Shortcuts")),
        .init(id: "backup", status: .planned,
              title: String(localized: "백업과 내보내기", comment: "Roadmap item: backup and export"),
              detail: String(localized: "발표를 파일로 저장하고 다시 불러올 수 있어요.", comment: "Roadmap item detail: backup and export")),
        .init(id: "lock.faceid", status: .planned,
              title: String(localized: "Face ID 잠금", comment: "Roadmap item: Face ID lock"),
              detail: String(localized: "Face ID나 Touch ID로 앱을 잠가 내 발표를 지켜요.", comment: "Roadmap item detail: Face ID lock")),
        .init(id: "fold", status: .planned,
              title: String(localized: "펼치는 아이폰 화면", comment: "Roadmap item: foldable iPhone layout"),
              detail: String(localized: "펼치는 아이폰에서 넓은 화면을 두 쪽으로 나눠 써요.", comment: "Roadmap item detail: foldable iPhone layout")),
        .init(id: "data.delete", status: .planned,
              title: String(localized: "내 데이터 한 번에 지우기", comment: "Roadmap item: delete all my data"),
              detail: String(localized: "원하면 앱 안에서 내 발표를 모두 지울 수 있어요.", comment: "Roadmap item detail: delete all my data")),
        .init(id: "autosave", status: .planned,
              title: String(localized: "찍던 발표 이어서 하기", comment: "Roadmap item: keep slides captured so far"),
              detail: String(localized: "장표를 찍다가 앱이 꺼져도 찍던 내용이 남아 있어요.", comment: "Roadmap item detail: keep slides captured so far")),
    ]}
}

// MARK: - 화면

/// 내 정보 ▸ 앞으로 만들 기능. "이런 기능이 있으면 좋겠어요" 는 기능 제안으로 시작하는 피드백 창을 연다.
struct RoadmapScreen: View {
    @State private var showFeedback = false

    var body: some View {
        LeeoRoadmapView<SlideSnapSpec>(onSuggest: { showFeedback = true })
            .sheet(isPresented: $showFeedback) {
                // 앱의 피드백 래퍼 — 이름·이메일을 내 정보에서 채운다(LeeoFeedbackView 가 NavigationStack 을 갖고 있다).
                FeedbackView(initialType: .feature)
            }
    }
}
