//
//  ProfileView.swift
//  SlideSnap
//
//  "내 정보" — 이름·회신용 이메일을 입력하면 iCloud에 안전하게 보관되고
//  같은 Apple ID의 다른 기기와 동기화된다. 피드백을 보낼 때 회신처로 자동 첨부된다.
//

import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var profile: UserProfileStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var email = ""
    @State private var justSaved = false

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

    private func save() {
        profile.name = name.trimmed
        profile.email = email.trimmed
        withAnimation { justSaved = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { dismiss() }
    }
}
