//
//  LaunchCamera.swift
//  SlideSnap
//
//  앱을 열 때 카메라를 띄울지, 새 발표 이름을 무엇으로 할지, 이어 찍을 발표가 있는지 — "찍으러 왔을 때" 의 판단을 한 곳에.
//  설정 ▸ 촬영과 발표 목록이 같이 읽는다.
//

import Foundation
import EventKit

/// 앱을 열었을 때 무엇부터 보일지.
enum LaunchCamera: String, CaseIterable, Identifiable {
    /// 늘 카메라부터 (처음 값 — 유료 앱일 때부터 이렇게 열렸다)
    case always
    /// 찍던 중이면 카메라, 아니면 목록
    case smart
    /// 늘 목록부터
    case never

    static let key = "launchCamera"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .always: String(localized: "바로 촬영")
        case .smart:  String(localized: "알아서")
        case .never:  String(localized: "목록부터")
        }
    }

    var footer: String {
        switch self {
        case .always: String(localized: "앱을 열면 카메라가 바로 떠요.")
        case .smart:  String(localized: "최근에 찍었거나 지금 캘린더 일정이 있으면 카메라부터, 아니면 발표 목록부터 보여요.")
        case .never:  String(localized: "발표 목록부터 보여요. 위젯이나 제어 센터, 단축어로는 언제든 바로 찍을 수 있어요.")
        }
    }

    /// '찍던 중' 으로 보는 시간 — 마지막 장표가 이보다 최근이면 강의 · 학회가 아직 이어지는 중이다.
    static let ongoingWindow: TimeInterval = 2 * 60 * 60

    /// 지금 카메라를 열지. 처음 쓰는 사람(발표가 없다)에게는 늘 카메라부터 — 이 앱이 무엇인지 그게 말해 준다.
    func opensCamera(lastCapture: Date?, hasPresentations: Bool, now: Date = Date()) -> Bool {
        switch self {
        case .always: return true
        case .never:  return false
        case .smart:
            if !hasPresentations { return true }
            if let lastCapture, now.timeIntervalSince(lastCapture) < Self.ongoingWindow { return true }
            return CalendarNaming.currentEventTitle(at: now) != nil
        }
    }
}

/// 이어 찍을 발표 — 새 발표로 카메라를 열었지만, 하루 안에 찍던 발표가 있으면 카메라 위에서 이어 찍기를 권한다.
/// (5분 안이면 묻지 않고 이어 붙인다 → PresentationListView.openCamera)
enum ContinueCapture {
    static let window: TimeInterval = 24 * 60 * 60

    static func candidate(in presentations: [Presentation], now: Date = Date()) -> Presentation? {
        guard let recent = presentations.first,
              let last = recent.slides.last?.createdAt,
              now.timeIntervalSince(last) < window else { return nil }
        return recent
    }
}

/// 지금 캘린더 일정으로 새 발표 이름 짓기. 설정 ▸ 촬영에서 켜야 하고(처음엔 꺼짐), 켜면 캘린더 접근을 묻는다.
/// 일정은 이 기기 안에서 읽기만 한다 — 어디에도 보내지 않는다.
enum CalendarNaming {
    static let key = "calendarNaming"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: key) && EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// 켜려고 할 때 접근을 묻는다. 허락받았으면 true.
    static func requestAccess() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return true
        case .notDetermined: return (try? await EKEventStore().requestFullAccessToEvents()) ?? false
        default: return false
        }
    }

    /// 지금 진행 중인 일정 이름. 종일 일정은 강의 · 발표가 아니라 빼고, 여럿이면 가장 늦게 시작한 것.
    static func currentEventTitle(at now: Date = Date()) -> String? {
        guard isEnabled else { return nil }
        let store = EKEventStore()
        // 시작 10분 전에 자리에 앉아 찍기 시작하는 일도 일정 안으로 본다.
        let predicate = store.predicateForEvents(withStart: now, end: now.addingTimeInterval(10 * 60), calendars: nil)
        return store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now }
            .max { $0.startDate < $1.startDate }?
            .title?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
