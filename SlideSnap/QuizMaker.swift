import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// 장표마다 복습 문제 하나를 기기 안의 Apple 언어 모델로 만든다.
///
/// 장표 한 장씩 따로 묻는다. 기기 모델은 한 번에 읽는 분량이 작고, 문제는 그 장표만 보고 풀 수 있어야 하기 때문이다.
/// 글자가 거의 없는 장표(사진 · 그림만 있는 장표)는 건너뛴다.
enum QuizMaker {

    enum Failure: LocalizedError {
        case noContent

        var errorDescription: String? {
            String(localized: "문제를 만들 글자가 없어요. 글자가 있는 장표여야 문제를 만들 수 있어요.")
        }
    }

    /// 문제를 만들 만큼 글자가 있는 장표와 그 글자.
    static func sources(in presentation: Presentation) -> [(slideID: UUID, text: String)] {
        presentation.slides.compactMap { slide in
            let parts = [slide.recognizedText, slide.memo]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let text = parts.joined(separator: "\n")
            return text.count >= 20 ? (slide.id, String(text.prefix(1_500))) : nil
        }
    }

    /// - Parameter onProgress: 0...1 진행률
    static func make(
        _ presentation: Presentation,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws -> [QuizCard] {
        let sources = sources(in: presentation)
        guard !sources.isEmpty else { throw Failure.noContent }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, visionOS 26.0, *) {
            let status = Summarizer.status
            guard status == .available else { throw Summarizer.Failure.unavailable(status) }
            let language = Summarizer.answerLanguage(for: sources.map(\.text).joined(separator: "\n"))
            var cards: [QuizCard] = []
            for (index, source) in sources.enumerated() {
                try Task.checkCancellation()
                // 한 장이 실패해도(안전 거절 등) 나머지 장표는 만든다.
                if let card = try? await ModelQuizMaker.question(for: source.text, title: presentation.title, language: language) {
                    cards.append(QuizCard(slideID: source.slideID, question: card.question, answer: card.answer))
                }
                await onProgress(Double(index + 1) / Double(sources.count))
            }
            guard !cards.isEmpty else { throw Failure.noContent }
            return cards
        }
        #endif
        throw Summarizer.Failure.unavailable(.unsupportedDevice)
    }
}

#if canImport(FoundationModels)

@available(iOS 26.0, visionOS 26.0, *)
@Generable
private struct GeneratedQuestion {
    @Guide(description: "One short question that checks whether the student understood the key idea of this slide.")
    var question: String
    @Guide(description: "The answer in one or two short sentences, taken only from the slide.")
    var answer: String
}

@available(iOS 26.0, visionOS 26.0, *)
private enum ModelQuizMaker {
    static func question(for text: String, title: String, language: String) async throws -> GeneratedQuestion {
        let session = LanguageModelSession(instructions: """
            You help a student review a lecture by writing flashcard questions from its slides.
            Use only the information on the slide. Ask about the main idea, not about trivia like page numbers.
            Always write the question and the answer in \(language).
            """)
        let prompt = """
            Lecture: \(title)

            Slide text:
            \(text)

            Write one review question and its answer in \(language).
            """
        return try await session.respond(to: prompt, generating: GeneratedQuestion.self).content
    }
}

#endif
