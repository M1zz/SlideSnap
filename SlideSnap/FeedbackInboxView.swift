//
//  FeedbackInboxView.swift
//  SlideSnap
//
//  개발자 전용 피드백 수신함 (마스터 모드) — CloudKit Public DB의 Feedback 레코드를
//  앱 안에서 직접 조회한다. 진입점은 "내 정보"의 버전 행 7번 탭으로 열리는 개발자 모드.
//
//  ⚠️ CloudKit Dashboard 설정 필요 (조회가 되려면):
//  - Feedback 레코드 타입의 recordName에 Queryable 인덱스 추가
//  - Security Roles에 admin 역할을 만들어 read 권한을 주고,
//    이 화면 하단에 표시되는 내 사용자 ID를 admin 역할에 등록
//    (World/Authenticated에는 create만 — 다른 사용자는 읽지 못한다)
//

import SwiftUI
import CloudKit

// MARK: - 조회 모델/서비스

struct FeedbackItem: Identifiable {
    let id: String
    let type: String
    let message: String
    let deviceInfo: String
    let contactName: String
    let contactEmail: String
    let appVersion: String
    let locale: String
    let platform: String
    let createdAt: Date?

    init(record: CKRecord) {
        id = record.recordID.recordName
        type = record["type"] as? String ?? "-"
        message = record["message"] as? String ?? ""
        deviceInfo = record["deviceInfo"] as? String ?? ""
        contactName = record["contactName"] as? String ?? ""
        contactEmail = record["contactEmail"] as? String ?? ""
        appVersion = record["appVersion"] as? String ?? "-"
        locale = record["locale"] as? String ?? "-"
        platform = record["platform"] as? String ?? "-"
        createdAt = record.creationDate
    }
}

extension FeedbackService {
    /// 현재 iCloud 계정의 userRecordID.recordName (Dashboard admin 역할 등록용).
    func currentUserRecordName() async -> String? {
        let container = CKContainer(identifier: Self.containerIdentifier)
        return (try? await container.userRecordID())?.recordName
    }

    /// Public DB의 Feedback 레코드를 최신순으로 가져온다.
    func fetchAll(limit: Int = 100) async throws -> [FeedbackItem] {
        let container = CKContainer(identifier: Self.containerIdentifier)
        let query = CKQuery(recordType: Self.recordType, predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let (results, _) = try await container.publicCloudDatabase.records(
            matching: query,
            inZoneWith: nil,
            desiredKeys: nil,
            resultsLimit: limit
        )
        return results.compactMap { _, result in
            guard let record = try? result.get() else { return nil }
            return FeedbackItem(record: record)
        }
    }
}

// MARK: - 수신함 화면

struct FeedbackInboxView: View {
    @State private var items: [FeedbackItem] = []
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var myRecordName: String?
    // 새 피드백 푸시 알림 (CKQuerySubscription — 서버 기준 상태)
    @State private var notifyEnabled = false
    @State private var notifyLoaded = false

    var body: some View {
        List {
            Section {
                Toggle(isOn: Binding(
                    get: { notifyEnabled },
                    set: { setNotify($0) }
                )) {
                    Label("새 피드백 알림", systemImage: "bell.badge")
                }
                .disabled(!notifyLoaded)
            } footer: {
                Text("새 피드백이 접수되면 이 기기로 푸시 알림이 와요. CloudKit admin 역할의 read 권한 설정 후에 동작해요.")
            }

            if let errorText {
                Section {
                    Label(errorText, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }

            if items.isEmpty && !isLoading && errorText == nil {
                Section {
                    Text("아직 접수된 피드백이 없어요.")
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(items) { item in
                NavigationLink {
                    FeedbackInboxDetailView(item: item)
                } label: {
                    row(item)
                }
            }

            if let myRecordName {
                Section {
                    Text(myRecordName)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                } header: {
                    Text("내 사용자 ID")
                } footer: {
                    Text("CloudKit Dashboard의 admin 역할에 이 ID를 추가하면 앱에서 모든 피드백을 읽을 수 있어요.")
                }
            }
        }
        .navigationTitle("접수된 피드백")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isLoading { ProgressView() }
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func row(_ item: FeedbackItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.type)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                Spacer()
                if let date = item.createdAt {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(item.message)
                .font(.subheadline)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }

    private func load() async {
        isLoading = true
        errorText = nil
        defer { isLoading = false }

        myRecordName = await FeedbackService.shared.currentUserRecordName()
        if !notifyLoaded {
            notifyEnabled = await FeedbackService.shared.isNewFeedbackNotificationEnabled()
            notifyLoaded = true
        }
        do {
            items = try await FeedbackService.shared.fetchAll()
        } catch {
            errorText = Self.hint(for: error)
        }
    }

    /// 새 피드백 푸시 알림 켜기/끄기 — CKQuerySubscription 등록/해제.
    private func setNotify(_ enabled: Bool) {
        Task {
            do {
                if enabled {
                    try await FeedbackService.shared.enableNewFeedbackNotifications()
                } else {
                    try await FeedbackService.shared.disableNewFeedbackNotifications()
                }
                notifyEnabled = enabled
            } catch {
                errorText = "알림 설정을 처리하지 못했어요: \(error.localizedDescription)"
            }
        }
    }

    /// CloudKit 오류를 개발자가 조치할 수 있는 안내문으로 바꾼다.
    private static func hint(for error: Error) -> String {
        let text = String(describing: error)
        if text.contains("queryable") {
            return "CloudKit Dashboard > Indexes에서 Feedback의 recordName에 Queryable 인덱스를 추가한 뒤 다시 시도하세요."
        }
        if text.localizedCaseInsensitiveContains("permission")
            || text.localizedCaseInsensitiveContains("not authenticated") {
            return "조회 권한이 없어요. Dashboard > Security Roles의 admin 역할에 read 권한과 아래 사용자 ID를 등록했는지, 기기가 iCloud에 로그인돼 있는지 확인하세요."
        }
        return "불러오지 못했어요: \(error.localizedDescription)"
    }
}

// MARK: - 상세 화면

struct FeedbackInboxDetailView: View {
    let item: FeedbackItem

    var body: some View {
        List {
            Section("내용") {
                Text(item.message)
                    .textSelection(.enabled)
            }

            if !item.contactName.isEmpty || !item.contactEmail.isEmpty {
                Section("회신처") {
                    if !item.contactName.isEmpty {
                        LabeledContent("이름", value: item.contactName)
                    }
                    if !item.contactEmail.isEmpty {
                        LabeledContent("이메일", value: item.contactEmail)
                            .textSelection(.enabled)
                        if let url = URL(string: "mailto:\(item.contactEmail)") {
                            Link("메일로 답장하기", destination: url)
                        }
                    }
                }
            }

            Section("환경") {
                LabeledContent("유형", value: item.type)
                LabeledContent("앱 버전", value: item.appVersion)
                LabeledContent("플랫폼", value: item.platform)
                LabeledContent("언어", value: item.locale)
                if !item.deviceInfo.isEmpty {
                    Text(item.deviceInfo)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let date = item.createdAt {
                    LabeledContent("접수 시각",
                                   value: date.formatted(date: .long, time: .standard))
                }
            }
        }
        .navigationTitle(item.type)
        .navigationBarTitleDisplayMode(.inline)
    }
}
