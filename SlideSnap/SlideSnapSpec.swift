//
//  SlideSnapSpec.swift
//  SlideSnap
//
//  LeeoKit 계약(LeeoAppSpec) 준수 — 이 앱의 공통 기능 설정값 단일 소스.
//  피드백 시스템 구현은 전부 LeeoKit에 있고, 앱은 이 설정만 제공한다.
//
//  ⚠️ feedback의 컨테이너/레코드 타입/구독 ID는 CloudKit Dashboard·기존 사용자
//  기기와의 계약이다 — 변경 금지.
//

import Foundation
import LeeoKit

enum SlideSnapSpec: LeeoAppSpec {
    static let appName = "장표스냅"
    static let developerEmail = AppInfo.developerEmail

    /// SlideSnap.entitlements의 iCloud 컨테이너와 동일해야 한다.
    /// appIdentifier는 nil — 단일 앱 스키마 (기존 배포 스키마와 호환).
    static let feedback = LeeoFeedbackConfig(
        containerIdentifier: "iCloud.com.leeo.slidesnap"
    )
}

/// 앱 전역에서 쓰는 상수 (기존 FeedbackService.swift에서 이동).
enum AppInfo {
    /// 피드백 이메일 폴백 수신 주소.
    static let developerEmail = "leeo@kakao.com"

    /// 현재 앱 버전 (예: "1.0").
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
    }
}
