//
//  ProfileView.swift
//  SlideSnap
//
//  "내 정보" — 이름·회신용 이메일을 입력하면 iCloud에 안전하게 보관되고
//  같은 Apple ID의 다른 기기와 동기화된다. 피드백을 보낼 때 회신처로 자동 첨부된다.
//

import SwiftUI
import LeeoKit

struct ProfileView: View {
    @EnvironmentObject private var profile: UserProfileStore
    @EnvironmentObject private var cloudSync: CloudSync
    @State private var enablingSync = false
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var email = ""
    @State private var justSaved = false

    /// 마스터(개발자) 모드 — 버전 행 7번 탭으로 토글. 피드백 수신함 진입점 노출.
    @AppStorage("dev.masterMode") private var masterModeEnabled = false
    @State private var versionTapCount = 0
    @State private var showMasterModeAlert = false

    private var isValidEmail: Bool {
        let e = email.trimmed
        return e.isEmpty || (e.contains("@") && e.contains("."))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("이름", text: $name)
                        .textContentType(.name)
                    TextField("이메일", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("내 정보")
                } footer: {
                    if !isValidEmail {
                        Text("이메일 형식을 확인해 주세요.")
                            .foregroundStyle(.red)
                    } else {
                        Text("여기에 저장한 정보는 내 iCloud에만 보관되며, 피드백을 보낼 때 회신처로 자동 첨부됩니다.")
                    }
                }

                Section {
                    Label("iCloud에 저장돼 다른 기기와 자동으로 동기화돼요.",
                          systemImage: "icloud")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle(isOn: syncBinding) {
                        Label("iCloud 동기화", systemImage: "arrow.triangle.2.circlepath.icloud")
                    }
                    .disabled(enablingSync)
                    if cloudSync.isEnabled {
                        Button {
                            Task { await cloudSync.syncNow() }
                        } label: {
                            HStack {
                                Text("지금 동기화")
                                Spacer()
                                if cloudSync.isSyncing || enablingSync { ProgressView() }
                            }
                        }
                        .disabled(cloudSync.isSyncing)
                    }
                } header: {
                    Text("발표 동기화")
                } footer: {
                    syncFooter
                }

                Section("앱 정보") {
                    LabeledContent("버전", value: AppInfo.appVersion)
                        .contentShape(Rectangle())
                        .onTapGesture { handleVersionTap() }
                }

                if masterModeEnabled {
                    Section("개발자") {
                        NavigationLink {
                            FeedbackInboxView()
                        } label: {
                            Label("접수된 피드백", systemImage: "tray.full")
                        }
                        NavigationLink {
                            LeeoUsageStatsView<SlideSnapSpec>()
                        } label: {
                            Label("사용 통계", systemImage: "chart.bar.xaxis")
                        }
                    }
                }
            }
            .navigationTitle("내 정보")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장", action: save)
                        .disabled(!isValidEmail)
                        .fontWeight(.semibold)
                }
            }
            .onAppear {
                name = profile.name
                email = profile.email
            }
            .alert(
                masterModeEnabled ? String(localized: "개발자 모드가 켜졌어요") : String(localized: "개발자 모드가 꺼졌어요"),
                isPresented: $showMasterModeAlert
            ) {
                Button("확인", role: .cancel) {}
            } message: {
                if masterModeEnabled {
                    Text("아래에 '접수된 피드백' 메뉴가 나타납니다.")
                }
            }
            .overlay(alignment: .bottom) {
                if justSaved {
                    Label("저장했어요", systemImage: "checkmark.circle.fill")
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    private var syncBinding: Binding<Bool> {
        Binding(
            get: { cloudSync.isEnabled },
            set: { on in
                if on {
                    enablingSync = true
                    Task {
                        await cloudSync.enable()
                        if cloudSync.isEnabled { UIApplication.shared.registerForRemoteNotifications() }
                        enablingSync = false
                    }
                } else {
                    cloudSync.disable()
                }
            }
        )
    }

    @ViewBuilder
    private var syncFooter: some View {
        if let error = cloudSync.lastError {
            Text(error).foregroundStyle(.red)
        } else if cloudSync.isEnabled, let last = cloudSync.lastSyncedAt {
            Text("마지막 동기화: \(last.formatted(.relative(presentation: .named)))")
        } else {
            Text("같은 Apple ID로 로그인한 iPhone·iPad·Mac에서 발표·장표·녹음을 함께 봐요. 사진과 녹음이 iCloud 저장 공간을 사용해요.")
        }
    }

    /// 버전 행 7번 탭 → 마스터(개발자) 모드 토글.
    private func handleVersionTap() {
        versionTapCount += 1
        guard versionTapCount >= 7 else { return }
        versionTapCount = 0
        masterModeEnabled.toggle()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        showMasterModeAlert = true
    }

    private func save() {
        profile.name = name.trimmed
        profile.email = email.trimmed
        withAnimation { justSaved = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { dismiss() }
    }
}
