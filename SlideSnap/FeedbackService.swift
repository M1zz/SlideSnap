//
//  FeedbackService.swift
//  SlideSnap
//
//  앱 내 피드백/기능 요청을 CloudKit Public Database로 직접 제출한다.
//  메일 앱 없이도 동작하며, 개발자는 CloudKit Dashboard에서 접수 내역을 확인한다.
//
//  ⚠️ CloudKit Dashboard 설정 필요:
//  - Public DB에 "Feedback" 레코드 타입 (개발 환경에서 첫 저장 시 자동 생성)
//  - Security Roles: World에 create만 허용, read 권한 제거
//  - 스키마를 Production으로 배포
//

import Foundation
import CloudKit
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

/// 앱 전역에서 쓰는 상수.
enum AppInfo {
    /// 피드백 이메일 폴백 수신 주소.
    static let developerEmail = "leeo@kakao.com"

    /// 현재 앱 버전 (예: "1.0").
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
    }
}

final class FeedbackService {
    static let shared = FeedbackService()
    private init() {}

    /// 앱 iCloud 컨테이너 (SlideSnap.entitlements와 동일해야 한다).
    static let containerIdentifier = "iCloud.com.leeo.slidesnap"
    static let recordType = "Feedback"

    enum FeedbackError: LocalizedError {
        case iCloudUnavailable
        case saveFailed(Error)

        var errorDescription: String? {
            switch self {
            case .iCloudUnavailable:
                return "iCloud에 로그인되어 있지 않아요"
            case .saveFailed:
                return "전송에 실패했어요"
            }
        }
    }

    /// 피드백을 Public DB에 제출한다. 실패 시 throw — 호출부에서 이메일 폴백 처리.
    /// - Parameters:
    ///   - contactName: 회신용 이름(선택). 비어 있으면 첨부하지 않는다.
    ///   - contactEmail: 회신용 이메일(선택). 비어 있으면 첨부하지 않는다.
    func submit(
        type: String,
        message: String,
        deviceInfo: String,
        contactName: String = "",
        contactEmail: String = ""
    ) async throws {
        let container = CKContainer(identifier: Self.containerIdentifier)

        // Public DB 쓰기도 iCloud 로그인이 필요하다.
        let status = try await container.accountStatus()
        guard status == .available else {
            print("⚠️ [FeedbackService.submit] iCloud 계정 없음: \(status)")
            throw FeedbackError.iCloudUnavailable
        }

        let record = CKRecord(recordType: Self.recordType)
        record["type"] = type
        record["message"] = message
        record["deviceInfo"] = deviceInfo
        record["contactName"] = contactName
        record["contactEmail"] = contactEmail
        record["appVersion"] = AppInfo.appVersion
        record["locale"] = Locale.current.identifier
        record["platform"] = {
            #if targetEnvironment(macCatalyst)
            return "macCatalyst"
            #else
            return "iOS"
            #endif
        }()

        do {
            _ = try await container.publicCloudDatabase.save(record)
            print("✅ [FeedbackService.submit] 피드백 제출 완료 (type=\(type))")
        } catch {
            print("❌ [FeedbackService.submit] 제출 실패: \(error)")
            throw FeedbackError.saveFailed(error)
        }
    }

    // MARK: - 새 피드백 푸시 알림 (개발자 기기 전용)

    /// 새 Feedback 레코드 생성 시 이 기기(iCloud 계정)로 오는 CKQuerySubscription ID.
    static let newFeedbackSubscriptionID = "feedback-new-v1"

    enum NotificationError: LocalizedError {
        case permissionDenied

        var errorDescription: String? {
            "알림 권한이 꺼져 있어요. iOS 설정 > 장표스냅 > 알림에서 허용해 주세요."
        }
    }

    /// 새 피드백 푸시 알림 구독 여부 (서버 기준 — 재설치해도 유지).
    func isNewFeedbackNotificationEnabled() async -> Bool {
        let db = CKContainer(identifier: Self.containerIdentifier).publicCloudDatabase
        let sub = try? await db.subscription(for: Self.newFeedbackSubscriptionID)
        return sub != nil
    }

    /// 새 피드백 푸시 알림 켜기 — 알림 권한 요청 + APNs 등록 + CKQuerySubscription 저장.
    /// ⚠️ 구독이 발화하려면 이 계정이 Feedback을 읽을 수 있어야 한다 (admin 역할 read).
    func enableNewFeedbackNotifications() async throws {
        #if canImport(UIKit)
        let granted = try await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
        guard granted else { throw NotificationError.permissionDenied }
        await MainActor.run {
            UIApplication.shared.registerForRemoteNotifications()
        }
        #endif

        let subscription = CKQuerySubscription(
            recordType: Self.recordType,
            predicate: NSPredicate(value: true),
            subscriptionID: Self.newFeedbackSubscriptionID,
            options: .firesOnRecordCreation
        )
        let info = CKSubscription.NotificationInfo()
        info.title = "새 피드백이 도착했어요 📬"
        info.alertBody = "사용자가 의견을 남겼어요. 수신함에서 확인해 보세요."
        info.soundName = "default"
        subscription.notificationInfo = info

        let db = CKContainer(identifier: Self.containerIdentifier).publicCloudDatabase
        _ = try await db.save(subscription)
        print("🔔 [FeedbackService.enableNewFeedbackNotifications] 구독 등록 완료")
    }

    /// 새 피드백 푸시 알림 끄기 — 구독 삭제.
    func disableNewFeedbackNotifications() async throws {
        let db = CKContainer(identifier: Self.containerIdentifier).publicCloudDatabase
        _ = try await db.deleteSubscription(withID: Self.newFeedbackSubscriptionID)
        print("🔕 [FeedbackService.disableNewFeedbackNotifications] 구독 해제 완료")
    }
}
