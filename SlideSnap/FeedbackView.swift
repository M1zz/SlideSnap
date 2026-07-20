//
//  FeedbackView.swift
//  SlideSnap
//
//  피드백 화면은 LeeoKit이 통째로 제공한다 — 여기는 프리필·유형 구성용 얇은 래퍼만 남긴다.
//  실제 구현: LeeoKit/Sources/LeeoKit/Feedback/
//

import SwiftUI
import LeeoKit

/// 기존 호출부(PresentationListView 등) 호환용 별칭 — rawValue는 서버 데이터와 계약이라 유지.
typealias FeedbackType = LeeoFeedbackType

struct FeedbackView: View {
    @EnvironmentObject private var profile: UserProfileStore

    /// 진입 시 미리 선택할 유형 (넛지에서 "개선 제안"으로 들어오는 경우 등).
    var initialType: FeedbackType = .improvement

    var body: some View {
        LeeoFeedbackView<SlideSnapSpec>(
            types: [.improvement, .bug, .feature, .other],
            initialType: initialType,
            showsContactFields: true,
            initialContactName: profile.name,
            initialContactEmail: profile.email
        )
    }
}

struct FeedbackInboxView: View {
    var body: some View {
        LeeoFeedbackInboxView<SlideSnapSpec>()
    }
}
