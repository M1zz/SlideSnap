//
//  FeedbackView.swift
//  SlideSnap
//
//  앱 내에서 개발자에게 바로 피드백을 보내는 화면.
//  1차: CloudKit Public DB로 직접 제출(메일 앱 불필요) → 실패 시 이메일 폴백.
//

import SwiftUI
#if canImport(MessageUI)
import MessageUI
#endif

// MARK: - Feedback Type

enum FeedbackType: String, CaseIterable, Identifiable {
    case improvement = "improvement"
    case bug         = "bug"
    case feature     = "feature"
    case other       = "other"

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .improvement: return "개선 제안"
        case .bug:         return "버그 신고"
        case .feature:     return "기능 요청"
        case .other:       return "기타"
        }
    }

    var icon: String {
        switch self {
        case .improvement: return "wand.and.stars"
        case .bug:         return "ladybug"
        case .feature:     return "lightbulb"
        case .other:       return "ellipsis.bubble"
        }
    }

    var placeholder: String {
        switch self {
        case .improvement: return "어떤 점이 불편하셨나요? 어떻게 바뀌면 더 좋을지 알려주세요.\n예) 촬영 후 목록으로 바로 안 돌아가서 아쉬워요."
        case .bug:         return "어떤 상황에서 문제가 생겼는지 알려주세요.\n예) 장표를 촬영하면 앱이 종료돼요."
        case .feature:     return "어떤 기능이 있으면 좋겠나요?\n예) 발표를 폴더로 묶고 싶어요."
        case .other:       return "자유롭게 의견을 남겨주세요."
        }
    }

    var emailSubject: String {
        "[\(localizedName)] 장표스냅 \(AppInfo.appVersion)"
    }
}

// MARK: - Feedback View

struct FeedbackView: View {
    /// 진입 시 미리 선택할 유형 (넛지에서 "개선 제안"으로 들어오는 경우 등).
    var initialType: FeedbackType = .improvement

    @EnvironmentObject private var profile: UserProfileStore
    @Environment(\.dismiss) private var dismiss

    @State private var selectedType: FeedbackType = .improvement
    @State private var message: String = ""
    @State private var contactName: String = ""
    @State private var contactEmail: String = ""

    @State private var isSending = false
    @State private var didSend = false
    @State private var showMailFallback = false
    @State private var mailUnavailableAlert = false

    private var deviceInfo: String {
        #if os(iOS)
        let d = UIDevice.current
        return "App \(AppInfo.appVersion) | \(d.model) | \(d.systemName) \(d.systemVersion)"
        #else
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "App \(AppInfo.appVersion) | macOS \(os.majorVersion).\(os.minorVersion)"
        #endif
    }

    private var canSend: Bool {
        !message.trimmed.isEmpty && !isSending
    }

    var body: some View {
        NavigationStack {
            Form {
                typeSection
                messageSection
                contactSection
                deviceSection
            }
            .navigationTitle("피드백 보내기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSending ? "보내는 중…" : "보내기", action: send)
                        .disabled(!canSend)
                        .fontWeight(.semibold)
                }
            }
            .onAppear {
                selectedType = initialType
                contactName = profile.name
                contactEmail = profile.email
            }
            .alert("메일 앱을 열 수 없어요", isPresented: $mailUnavailableAlert) {
                Button("확인", role: .cancel) {}
            } message: {
                Text("iCloud로 전송에 실패했고 메일 앱도 설정되어 있지 않아요. 잠시 후 다시 시도해 주세요.")
            }
            #if canImport(MessageUI)
            .sheet(isPresented: $showMailFallback) {
                MailComposeView(
                    subject: selectedType.emailSubject,
                    body: emailBody,
                    to: AppInfo.developerEmail
                ) { _ in
                    showMailFallback = false
                    markSent()
                }
                .ignoresSafeArea()
            }
            #endif
            .overlay { if didSend { sentConfirmation } }
            .interactiveDismissDisabled(isSending)
        }
    }

    // MARK: - Sections

    private var typeSection: some View {
        Section("무엇을 알려주실 건가요?") {
            Picker("유형", selection: $selectedType) {
                ForEach(FeedbackType.allCases) { type in
                    Label(type.localizedName, systemImage: type.icon).tag(type)
                }
            }
            .pickerStyle(.navigationLink)
        }
    }

    private var messageSection: some View {
        Section("내용") {
            ZStack(alignment: .topLeading) {
                if message.isEmpty {
                    Text(selectedType.placeholder)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $message)
                    .frame(minHeight: 140)
                    .scrollContentBackground(.hidden)
            }
        }
    }

    private var contactSection: some View {
        Section {
            TextField("이름 (선택)", text: $contactName)
                .textContentType(.name)
            TextField("회신 받을 이메일 (선택)", text: $contactEmail)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        } header: {
            Text("회신 정보")
        } footer: {
            Text("남겨주시면 답변을 드릴 수 있어요. ‘내 정보’에 저장해 두면 다음부터 자동으로 채워지고 iCloud에 안전하게 보관됩니다.")
        }
    }

    private var deviceSection: some View {
        Section("자동 첨부 정보") {
            Text(deviceInfo)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var sentConfirmation: some View {
        ZStack {
            Color(.systemBackground).opacity(0.001)
            VStack(spacing: 16) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.green)
                Text("피드백을 보냈어요!\n소중한 의견 감사합니다 🙏")
                    .font(.headline)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .shadow(radius: 16, y: 8)
            .padding(40)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }

    // MARK: - Send

    private var emailBody: String {
        var lines = [message, "", "---"]
        if !contactName.trimmed.isEmpty { lines.append("이름: \(contactName.trimmed)") }
        if !contactEmail.trimmed.isEmpty { lines.append("회신 이메일: \(contactEmail.trimmed)") }
        lines.append(deviceInfo)
        return lines.joined(separator: "\n")
    }

    /// 1차 CloudKit 제출 → 실패 시 이메일 폴백.
    private func send() {
        isSending = true
        Task {
            do {
                try await FeedbackService.shared.submit(
                    type: selectedType.rawValue,
                    message: message,
                    deviceInfo: deviceInfo,
                    contactName: contactName.trimmed,
                    contactEmail: contactEmail.trimmed
                )
                await MainActor.run {
                    isSending = false
                    markSent()
                }
            } catch {
                print("⚠️ [FeedbackView.send] CloudKit 실패 → 이메일 폴백: \(error)")
                await MainActor.run {
                    isSending = false
                    fallbackToEmail()
                }
            }
        }
    }

    private func fallbackToEmail() {
        #if canImport(MessageUI)
        if MFMailComposeViewController.canSendMail() {
            showMailFallback = true
        } else {
            openMailtoURL()
        }
        #else
        openMailtoURL()
        #endif
    }

    private func openMailtoURL() {
        let raw = "mailto:\(AppInfo.developerEmail)?subject=\(selectedType.emailSubject)&body=\(emailBody)"
        guard let encoded = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: encoded) else {
            mailUnavailableAlert = true
            return
        }
        #if canImport(UIKit)
        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
            markSent()
        } else {
            mailUnavailableAlert = true
        }
        #endif
    }

    private func markSent() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { didSend = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { dismiss() }
    }
}

// MARK: - Mail Compose Wrapper

#if canImport(MessageUI)
struct MailComposeView: UIViewControllerRepresentable {
    let subject: String
    let body: String
    let to: String
    var onFinish: (MFMailComposeResult) -> Void

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.mailComposeDelegate = context.coordinator
        vc.setToRecipients([to])
        vc.setSubject(subject)
        vc.setMessageBody(body, isHTML: false)
        return vc
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onFinish: (MFMailComposeResult) -> Void
        init(onFinish: @escaping (MFMailComposeResult) -> Void) { self.onFinish = onFinish }

        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult,
                                   error: Error?) {
            controller.dismiss(animated: true) { self.onFinish(result) }
        }
    }
}
#endif
