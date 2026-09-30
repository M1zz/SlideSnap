import Foundation
import NaturalLanguage
#if canImport(FoundationModels)
import FoundationModels
#endif

/// 발표 내용(장표 글자 + 받아쓴 말)을 기기 안의 Apple 언어 모델로 요약한다.
///
/// 기기 모델은 한 번에 읽을 수 있는 분량이 작아서, 긴 발표는 조각마다 먼저 메모를 만들고
/// 그 메모들을 다시 모아 최종 요약을 만든다.
enum Summarizer {

    enum Status: Equatable {
        case available
        /// iOS 26 미만이거나 Apple Intelligence를 지원하지 않는 기기
        case unsupportedDevice
        /// 설정에서 Apple Intelligence가 꺼져 있음
        case intelligenceOff
        /// 모델을 내려받는 중 등
        case notReady

        var message: String {
            switch self {
            case .available:
                return ""
            case .unsupportedDevice:
                return String(localized: "AI 요약은 Apple Intelligence를 지원하는 기기(iOS 26 이상)에서 쓸 수 있어요.")
            case .intelligenceOff:
                return String(localized: "설정 ▸ Apple Intelligence 및 Siri에서 Apple Intelligence를 켜면 AI 요약을 쓸 수 있어요.")
            case .notReady:
                return String(localized: "Apple Intelligence 모델을 준비하는 중이에요. 잠시 후 다시 시도해 주세요.")
            }
        }
    }

    enum Failure: LocalizedError {
        case unavailable(Status)
        case noContent

        var errorDescription: String? {
            switch self {
            case .unavailable(let status): return status.message
            case .noContent: return String(localized: "요약할 내용이 없어요. 장표 글자를 인식하거나 녹음을 받아쓴 뒤 다시 시도해 주세요.")
            }
        }
    }

    static var status: Status {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(.appleIntelligenceNotEnabled):
                return .intelligenceOff
            case .unavailable(.modelNotReady):
                return .notReady
            default:
                return .unsupportedDevice
            }
        }
        #endif
        return .unsupportedDevice
    }

    /// 요약에 넣을 발표 원문. 장표마다 번호·장표 글자·그때 한 말을 붙인다.
    static func sourceText(for presentation: Presentation) -> [String] {
        presentation.slides.enumerated().compactMap { index, slide in
            var parts: [String] = []
            if let ocr = slide.recognizedText?.trimmingCharacters(in: .whitespacesAndNewlines), !ocr.isEmpty {
                parts.append(String(localized: "장표 글자: \(ocr)"))
            }
            if let spoken = presentation.transcriptText(for: slide) {
                parts.append(String(localized: "발표자: \(spoken)"))
            }
            guard !parts.isEmpty else { return nil }
            return "[\(index + 1)]\n" + parts.joined(separator: "\n")
        }
    }

    /// - Parameter onProgress: 0...1 진행률
    static func summarize(
        _ presentation: Presentation,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws -> PresentationSummary {
        let blocks = sourceText(for: presentation)
        guard !blocks.isEmpty else { throw Failure.noContent }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let status = status
            guard status == .available else { throw Failure.unavailable(status) }
            let language = answerLanguage(for: blocks.joined(separator: "\n"))
            return try await ModelSummarizer(title: presentation.title, language: language)
                .run(blocks: blocks, onProgress: onProgress)
        }
        #endif
        throw Failure.unavailable(.unsupportedDevice)
    }

    /// 발표에 쓰인 언어로 답하게 한다(영어 강의는 영어로, 한국어 강의는 한국어로).
    static func answerLanguage(for text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(4_000)))
        let code = recognizer.dominantLanguage?.rawValue
            ?? Bundle.main.preferredLocalizations.first
            ?? "ko"
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? "Korean"
    }
}

#if canImport(FoundationModels)

@available(iOS 26.0, *)
@Generable
private struct GeneratedSummary {
    @Guide(description: "A 2-4 sentence overview of what the whole talk was about.")
    var overview: String
    @Guide(description: "The most important takeaways, one short sentence each.", .count(3...7))
    var keyPoints: [String]
    @Guide(description: "Short keywords or terms from the talk.", .count(3...8))
    var keywords: [String]
}

@available(iOS 26.0, *)
private struct ModelSummarizer {
    let title: String
    /// 답할 언어의 영어 이름 (예: "Korean")
    let language: String

    /// 한 번에 모델에 넣을 원문 글자 수. 한국어는 글자당 토큰이 많아 넉넉히 작게 잡는다.
    private let chunkLimit = 1_800

    init(title: String, language: String) {
        self.title = title
        self.language = language
    }

    private var instructions: String {
        """
        You help a student review a lecture or conference talk they attended.
        The input is text read from the slides and what the speaker said.
        Be accurate and only use information in the input. Always write your answer in \(language).
        """
    }

    func run(blocks: [String], onProgress: @escaping @MainActor (Double) -> Void) async throws -> PresentationSummary {
        await onProgress(0.02)
        // 1) 조각마다 메모를 만든다(맵). 메모가 여전히 길면 한 번 더 줄인다.
        var notes = blocks
        var round = 0
        while notes.joined(separator: "\n").count > chunkLimit && round < 3 {
            let chunks = Self.chunk(notes, limit: chunkLimit)
            var next: [String] = []
            for (index, chunk) in chunks.enumerated() {
                next.append(try await noteFor(chunk))
                await onProgress(0.05 + 0.8 * Double(index + 1) / Double(chunks.count) / Double(round + 1))
            }
            notes = next
            round += 1
        }

        // 2) 모은 메모로 최종 요약(리듀스)
        let session = LanguageModelSession(instructions: instructions)
        let prompt = """
        Talk title: \(title)

        \(String(notes.joined(separator: "\n\n").prefix(chunkLimit + 400)))

        Summarize this talk for review. Write everything in \(language).
        """
        let response = try await session.respond(to: prompt, generating: GeneratedSummary.self)
        await onProgress(1)
        let result = response.content
        return PresentationSummary(
            overview: result.overview,
            keyPoints: result.keyPoints,
            keywords: result.keywords,
            generatedAt: Date()
        )
    }

    /// 원문 조각 하나를 짧은 메모로 줄인다. 너무 길다고 거절되면 반으로 나눠 다시 한다.
    private func noteFor(_ text: String) async throws -> String {
        do {
            let session = LanguageModelSession(instructions: instructions)
            let prompt = """
            Part of the talk "\(title)":

            \(text)

            Write concise review notes (at most 6 bullet lines) covering the key facts in this part, in \(language).
            """
            return try await session.respond(to: prompt).content
        } catch where Self.isContextOverflow(error) && text.count > 400 {
            let middle = text.index(text.startIndex, offsetBy: text.count / 2)
            let first = try await noteFor(String(text[..<middle]))
            let second = try await noteFor(String(text[middle...]))
            return first + "\n" + second
        }
    }

    private static func isContextOverflow(_ error: Error) -> Bool {
        if case .exceededContextWindowSize? = error as? LanguageModelSession.GenerationError {
            return true
        }
        return String(describing: error).localizedCaseInsensitiveContains("context")
    }

    /// 블록들을 글자 수 한도 안에서 이어 붙여 조각으로 나눈다. 한 블록이 한도보다 크면 잘라 넣는다.
    static func chunk(_ blocks: [String], limit: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        for block in blocks {
            var rest = Substring(block)
            while !rest.isEmpty {
                let room = limit - current.count
                if room < 200 && !current.isEmpty {
                    chunks.append(current)
                    current = ""
                    continue
                }
                let piece = rest.prefix(max(room, 200))
                current += (current.isEmpty ? "" : "\n\n") + piece
                rest = rest.dropFirst(piece.count)
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}

#endif
