//
//  StudyView.swift
//  SlideSnap
//
//  공부하기 — 찍은 장표를 한 장씩 넘기며 떠올리고, 답을 본 뒤 '알았어요 · 다시 볼래요' 를 고른다.
//  고른 표시는 장표에 남아 iCloud 로 다른 기기에 이어진다. 그래서 iPhone 으로 찍고 Mac · iPad · Vision Pro 에서 복습한다.
//  복습 문제가 있으면(→ QuizMaker) 앞면에 문제를, 뒷면에 답을 보여 준다.
//

import SwiftUI

struct StudyView: View {
    let presentationID: UUID

    @EnvironmentObject private var store: Store
    @EnvironmentObject private var purchases: PurchaseManager
    @Environment(\.dismiss) private var dismiss

    private enum Scope: Hashable { case all, review }

    @State private var scope: Scope = .all
    /// 이번 바퀴에 도는 장표들. 바퀴를 시작할 때 정해 두고, 도중에 표시가 바뀌어도 그대로 돈다.
    @State private var deck: [UUID] = []
    @State private var index = 0
    @State private var revealed = false
    @State private var started = false

    @State private var makingQuiz = false
    @State private var quizProgress: Double = 0
    @State private var errorMessage: String?
    @State private var paywallFeature: ProFeature?

    private var presentation: Presentation? { store.presentation(presentationID) }
    private var finished: Bool { started && index >= deck.count }

    var body: some View {
        NavigationStack {
            Group {
                if let presentation {
                    if finished {
                        summary(presentation)
                    } else if let slide = currentSlide(in: presentation) {
                        card(slide, in: presentation)
                    } else {
                        ContentUnavailableView("공부할 장표가 없어요", systemImage: "rectangle.on.rectangle.angled")
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
            .navigationTitle(presentation?.title ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .top) { header }
        }
        .onAppear { if !started { startRound(.all) } }
        .paywall(for: $paywallFeature)
        .alert("문제를 만들지 못했어요", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - 바퀴

    private func slides(_ scope: Scope) -> [Slide] {
        let all = presentation?.slides ?? []
        return scope == .all ? all : all.filter { $0.studyMark == .review }
    }

    private func startRound(_ scope: Scope) {
        self.scope = scope
        deck = slides(scope).map(\.id)
        index = 0
        revealed = false
        started = true
    }

    private func currentSlide(in presentation: Presentation) -> Slide? {
        guard deck.indices.contains(index) else { return nil }
        return presentation.slides.first { $0.id == deck[index] }
    }

    private func mark(_ mark: StudyMark, _ slide: Slide) {
        store.setStudyMark(mark, slideID: slide.id, presentationID: presentationID)
        withAnimation(.snappy) {
            index += 1
            revealed = false
        }
    }

    // MARK: - 위쪽: 범위 · 진행

    @ViewBuilder
    private var header: some View {
        if !finished, !deck.isEmpty {
            VStack(spacing: 10) {
                let reviewCount = slides(.review).count
                if reviewCount > 0 || scope == .review {
                    Picker("범위", selection: Binding(get: { scope }, set: { startRound($0) })) {
                        Text("전체 \(slides(.all).count)").tag(Scope.all)
                        Text("다시 볼 것 \(reviewCount)").tag(Scope.review)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 360)
                }
                ProgressView(value: Double(index), total: Double(max(deck.count, 1)))
                    .frame(maxWidth: 520)
                    .accessibilityValue(Text(verbatim: "\(index + 1) / \(deck.count)"))
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    // MARK: - 카드

    private func card(_ slide: Slide, in presentation: Presentation) -> some View {
        let quiz = presentation.quizCard(for: slide.id)
        return ScrollView {
            VStack(spacing: 20) {
                Text(verbatim: "\(index + 1) / \(deck.count)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)

                SlideThumb(image: store.loadImage(store.displayFile(for: slide)), placeholderIcon: "photo")
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .frame(maxWidth: 720)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                    .accessibilityLabel("장표")

                if let quiz {
                    Text(quiz.question)
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 640)
                } else if !revealed {
                    Text("이 장표에서 배운 것을 떠올려 본 뒤 답을 보세요.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if revealed {
                    back(slide, quiz: quiz)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) { actions(slide) }
    }

    /// 뒷면 — 답, 내 메모, 장표 글자.
    private func back(_ slide: Slide, quiz: QuizCard?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let quiz {
                backSection("답", text: quiz.answer, emphasized: true)
            }
            if let memo = slide.memo {
                backSection("메모", text: memo)
            }
            if let text = slide.recognizedText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                backSection("장표 글자", text: text)
            }
            if quiz == nil, slide.memo == nil, (slide.recognizedText ?? "").isEmpty {
                Text("이 장표에는 글자나 메모가 없어요. 떠올린 내용이 맞았는지 스스로 골라 주세요.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func backSection(_ title: LocalizedStringKey, text: String, emphasized: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(emphasized ? .body.weight(.medium) : .callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 아래 단추 — 답 보기, 또는 다시 볼래요 · 알았어요. 키보드로도 된다(스페이스 · ← · →).
    private func actions(_ slide: Slide) -> some View {
        HStack(spacing: 12) {
            if revealed {
                Button {
                    mark(.review, slide)
                } label: {
                    Label("다시 볼래요", systemImage: "arrow.uturn.backward")
                        .frame(maxWidth: .infinity)
                }
                .tint(.orange)
                .keyboardShortcut(.leftArrow, modifiers: [])

                Button {
                    mark(.known, slide)
                } label: {
                    Label("알았어요", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .tint(.green)
                .keyboardShortcut(.rightArrow, modifiers: [])
            } else {
                Button {
                    withAnimation(.snappy) { revealed = true }
                } label: {
                    Label("답 보기", systemImage: "eye")
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.space, modifiers: [])
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .frame(maxWidth: 520)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    // MARK: - 한 바퀴 끝

    private func summary(_ presentation: Presentation) -> some View {
        let round = presentation.slides.filter { deck.contains($0.id) }
        let known = round.filter { $0.studyMark == .known }.count
        let review = slides(.review).count
        return VStack(spacing: 24) {
            Image(systemName: review == 0 ? "checkmark.seal.fill" : "arrow.triangle.2.circlepath")
                .font(.system(size: 56))
                .foregroundStyle(review == 0 ? .green : .orange)
            VStack(spacing: 8) {
                Text("한 바퀴 끝났어요")
                    .font(.title2.weight(.bold))
                Text("알았어요 \(known)장 · 다시 볼래요 \(round.count - known)장")
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 12) {
                if review > 0 {
                    Button {
                        startRound(.review)
                    } label: {
                        Text("다시 볼 장표 \(review)장 공부하기")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button {
                    startRound(.all)
                } label: {
                    Text("처음부터 다시")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
            .frame(maxWidth: 360)
        }
        .padding(32)
    }

    // MARK: - 툴바

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("닫기", systemImage: "xmark") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
            if makingQuiz {
                ProgressView(value: quizProgress)
                    .frame(width: 80)
                    .accessibilityLabel("복습 문제를 만드는 중이에요")
            } else if Summarizer.status == .available {
                Button {
                    makeQuiz()
                } label: {
                    Label(presentation?.quiz == nil ? "AI 복습 문제 만들기" : "복습 문제 다시 만들기",
                          systemImage: ProFeature.summary.icon("sparkles"))
                }
            }
        }
    }

    private func makeQuiz() {
        guard let presentation else { return }
        guard purchases.allows(.summary) else {
            paywallFeature = .summary
            return
        }
        makingQuiz = true
        quizProgress = 0
        Task {
            do {
                let quiz = try await QuizMaker.make(presentation) { quizProgress = $0 }
                store.setQuiz(quiz, presentationID: presentationID)
                revealed = false
            } catch {
                errorMessage = error.localizedDescription
            }
            makingQuiz = false
        }
    }
}
