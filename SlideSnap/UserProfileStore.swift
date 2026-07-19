//
//  UserProfileStore.swift
//  SlideSnap
//
//  사용자의 연락처 정보(이름·회신용 이메일)를 iCloud 키-값 저장소
//  (NSUbiquitousKeyValueStore)에 보관한다. 같은 Apple ID의 다른 기기와
//  자동으로 동기화되며, 피드백을 보낼 때 회신처로 자동 첨부된다.
//
//  ⚠️ iCloud Key-Value 저장을 쓰려면 SlideSnap.entitlements에
//  com.apple.developer.ubiquity-kvstore-identifier 가 있어야 한다.
//

import Foundation
import Combine

@MainActor
final class UserProfileStore: ObservableObject {

    /// 표시 이름 (회신 시 호칭).
    @Published var name: String {
        didSet { persist(Keys.name, name) }
    }

    /// 회신용 이메일.
    @Published var email: String {
        didSet { persist(Keys.email, email) }
    }

    /// 이름·이메일 중 하나라도 채워져 있는지.
    var hasContactInfo: Bool {
        !name.trimmed.isEmpty || !email.trimmed.isEmpty
    }

    private enum Keys {
        static let name = "profile.name"
        static let email = "profile.email"
    }

    /// 로컬 폴백 + 즉시 반영용. iCloud와 함께 미러링한다.
    private let defaults = UserDefaults.standard
    private let cloud = NSUbiquitousKeyValueStore.default
    private var observer: NSObjectProtocol?

    init() {
        // iCloud 값이 있으면 우선, 없으면 로컬 값을 사용한다.
        name = Self.read(Keys.name, cloud: cloud, defaults: defaults)
        email = Self.read(Keys.email, cloud: cloud, defaults: defaults)

        // 다른 기기에서 값이 바뀌면 반영한다.
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reloadFromCloud() }
        }
        cloud.synchronize()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: - 내부

    private func persist(_ key: String, _ value: String) {
        defaults.set(value, forKey: key)
        cloud.set(value, forKey: key)
        cloud.synchronize()
    }

    private func reloadFromCloud() {
        let cloudName = Self.read(Keys.name, cloud: cloud, defaults: defaults)
        let cloudEmail = Self.read(Keys.email, cloud: cloud, defaults: defaults)
        if cloudName != name { name = cloudName }
        if cloudEmail != email { email = cloudEmail }
    }

    private static func read(_ key: String, cloud: NSUbiquitousKeyValueStore, defaults: UserDefaults) -> String {
        if let v = cloud.string(forKey: key), !v.isEmpty { return v }
        return defaults.string(forKey: key) ?? ""
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
