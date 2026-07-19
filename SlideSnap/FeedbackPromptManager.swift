//
//  FeedbackPromptManager.swift
//  SlideSnap
//
//  "사용하면서 불편한 점이나 개선했으면 하는 점이 있나요?"를 적절한 시점에
//  한 번씩 물어보고, 있다고 하면 피드백 화면으로 유도한다.
//
//  트리거: 앱 실행 횟수가 임계값(3, 8, 이후 10회마다)에 도달하면 다음 실행에서
//  한 번 노출한다. "그만 보기"를 누르면 다시 묻지 않는다.
//

import Foundation
import Combine

@MainActor
final class FeedbackPromptManager: ObservableObject {

    /// 이번 실행에서 넛지를 띄워야 하는지.
    @Published var shouldPrompt = false

    private enum Keys {
        static let launchCount = "feedbackPrompt.launchCount"
        static let lastPromptedAt = "feedbackPrompt.lastPromptedCount"
        static let optedOut = "feedbackPrompt.optedOut"
    }

    /// 이 실행 횟수에 도달하면 물어본다.
    private static let milestones = [3, 8]
    /// milestones 이후에는 이 간격마다 물어본다.
    private static let recurringEvery = 10

    private let defaults = UserDefaults.standard

    /// 앱이 활성화될 때(콜드/포그라운드 전환) 호출. 실행 횟수를 올리고 넛지 여부를 판단한다.
    func registerLaunch() {
        guard !defaults.bool(forKey: Keys.optedOut) else { return }

        let count = defaults.integer(forKey: Keys.launchCount) + 1
        defaults.set(count, forKey: Keys.launchCount)

        let lastPrompted = defaults.integer(forKey: Keys.lastPromptedAt)
        guard isMilestone(count), count != lastPrompted else { return }

        defaults.set(count, forKey: Keys.lastPromptedAt)
        shouldPrompt = true
    }

    /// "그만 보기" — 이후로 넛지를 띄우지 않는다.
    func optOut() {
        defaults.set(true, forKey: Keys.optedOut)
        shouldPrompt = false
    }

    /// 넛지를 닫는다(이번 회차만). 다음 임계값에서 다시 물어본다.
    func dismiss() {
        shouldPrompt = false
    }

    private func isMilestone(_ count: Int) -> Bool {
        if Self.milestones.contains(count) { return true }
        let maxMilestone = Self.milestones.max() ?? 0
        return count > maxMilestone && (count - maxMilestone) % Self.recurringEvery == 0
    }
}
