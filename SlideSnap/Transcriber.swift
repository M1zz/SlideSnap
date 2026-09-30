import AVFoundation
import Speech

/// 녹음 파일을 기기 안에서 글로 받아쓴다.
///
/// iOS 26 이상은 긴 녹음에 맞춘 `SpeechAnalyzer`를 쓰고, 그 아래 버전은 `SFSpeechRecognizer`의
/// 기기 내 인식으로 받아쓴다. 어느 쪽이든 음성은 기기 밖으로 나가지 않는다.
enum Transcriber {

    enum Failure: LocalizedError {
        case notAuthorized
        case unsupportedLanguage
        case unavailable

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return String(localized: "설정에서 음성 인식 접근을 허용해 주세요.")
            case .unsupportedLanguage:
                return String(localized: "이 기기에서는 선택한 언어를 받아쓸 수 없어요.")
            case .unavailable:
                return String(localized: "지금은 받아쓰기를 할 수 없어요. 잠시 후 다시 시도해 주세요.")
            }
        }
    }

    /// 받아쓰기 언어 선택지
    static let languages: [(id: String, label: String)] = [
        ("ko-KR", String(localized: "한국어")),
        ("en-US", String(localized: "영어")),
        ("ja-JP", String(localized: "일본어")),
        ("zh-CN", String(localized: "중국어"))
    ]

    /// 앱 언어에 맞춘 기본 받아쓰기 언어
    static var defaultLanguage: String {
        Bundle.main.preferredLocalizations.first?.hasPrefix("en") == true ? "en-US" : "ko-KR"
    }

    /// - Parameter onProgress: 0...1 진행률 (알 수 있을 때만)
    static func transcribe(
        url: URL,
        localeID: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TranscriptSegment] {
        let locale = Locale(identifier: localeID)
        if #available(iOS 26.0, *), SpeechTranscriber.isAvailable {
            return try await transcribeWithAnalyzer(url: url, locale: locale, onProgress: onProgress)
        }
        return try await transcribeWithRecognizer(url: url, locale: locale)
    }

    // MARK: - iOS 26+: SpeechAnalyzer

    @available(iOS 26.0, *)
    private static func transcribeWithAnalyzer(
        url: URL,
        locale: Locale,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TranscriptSegment] {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw Failure.unsupportedLanguage
        }
        let transcriber = SpeechTranscriber(
            locale: supported,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        // 언어 모델이 아직 기기에 없으면 내려받는다(처음 한 번).
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        let file = try AVAudioFile(forReading: url)
        let total = Double(file.length) / file.processingFormat.sampleRate
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let collector = Task {
            var words: [Word] = []
            for try await result in transcriber.results {
                let end = result.range.end.seconds
                if total > 0, end.isFinite { onProgress(min(1, end / total)) }
                // 결과 하나가 여러 문장(수십 초)일 수 있어, 단어마다 붙은 시간으로 다시 나눈다.
                var runWords: [Word] = []
                for run in result.text.runs {
                    let piece = String(result.text[run.range].characters)
                    guard let range = run.audioTimeRange, range.start.seconds.isFinite else { continue }
                    runWords.append(Word(text: piece, start: range.start.seconds, end: range.end.seconds))
                }
                if runWords.isEmpty {
                    let start = result.range.start.seconds
                    runWords = [Word(
                        text: String(result.text.characters),
                        start: start.isFinite ? start : 0,
                        end: end.isFinite ? end : 0
                    )]
                }
                words += runWords
            }
            return group(words)
        }

        do {
            if let last = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            throw error
        }
        return try await collector.value
    }

    // MARK: - iOS 17~25: SFSpeechRecognizer

    private static func transcribeWithRecognizer(url: URL, locale: Locale) async throws -> [TranscriptSegment] {
        guard await requestAuthorization() else { throw Failure.notAuthorized }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else {
            throw Failure.unsupportedLanguage
        }
        guard recognizer.isAvailable else { throw Failure.unavailable }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true

        let words: [SFTranscriptionSegment] = try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !resumed else { return }
                if let error {
                    resumed = true
                    continuation.resume(throwing: error)
                } else if let result, result.isFinal {
                    resumed = true
                    continuation.resume(returning: result.bestTranscription.segments)
                }
            }
        }
        return group(words.map { Word(text: $0.substring + " ", start: $0.timestamp, end: $0.timestamp + $0.duration) })
    }

    /// 시간이 붙은 글자 조각. 띄어쓰기는 조각 안에 들어 있다.
    private struct Word {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
    }

    /// 단어 단위 결과를 문장 단위 토막으로 묶는다. 문장이 끝나거나, 말이 잠깐 끊기거나, 너무 길어지면 나눈다.
    private static func group(_ words: [Word]) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var current: TranscriptSegment?

        func close() {
            guard var open = current else { return }
            open.text = open.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !open.text.isEmpty { segments.append(open) }
            current = nil
        }

        for word in words {
            if let open = current, word.start - open.end > 1.2 || open.end - open.start > 20 {
                close()
            }
            if current == nil {
                current = TranscriptSegment(start: word.start, end: word.end, text: word.text)
            } else {
                current?.text += word.text
                current?.end = word.end
            }
            let trimmed = word.text.trimmingCharacters(in: .whitespaces)
            if let last = trimmed.last, ".?!。？！".contains(last) {
                close()
            }
        }
        close()
        return segments
    }

    private static func requestAuthorization() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .denied, .restricted: return false
        default:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        }
    }
}
