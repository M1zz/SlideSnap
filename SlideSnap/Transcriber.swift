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

    /// 이 기기가 기기 안에서 받아쓸 수 있는 언어(BCP 47), 이름순.
    static func languages() async -> [String] {
        var locales: [Locale]
        if #available(iOS 26.0, visionOS 26.0, *), SpeechTranscriber.isAvailable {
            locales = await SpeechTranscriber.supportedLocales + DictationTranscriber.supportedLocales
        } else {
            locales = SFSpeechRecognizer.supportedLocales().filter {
                SFSpeechRecognizer(locale: $0)?.supportsOnDeviceRecognition == true
            }
        }
        return Set(locales.map { $0.identifier(.bcp47) })
            .sorted { label($0).localizedStandardCompare(label($1)) == .orderedAscending }
    }

    /// 언어 이름을 앱 언어로. 예: "pl-PL" → "폴란드어(폴란드)"
    static func label(_ id: String) -> String {
        Locale.current.localizedString(forIdentifier: id) ?? id
    }

    /// 고른 언어가 목록에 없으면(예전 값 · 처음 실행) 같은 언어 중 가장 알맞은 것으로 바꾼다.
    static func resolve(_ id: String, in list: [String]) async -> String {
        if list.contains(id) { return id }
        if #available(iOS 26.0, visionOS 26.0, *), SpeechTranscriber.isAvailable {
            let locale = Locale(identifier: id)
            let speech = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
            let dictation = await DictationTranscriber.supportedLocale(equivalentTo: locale)
            if let match = (speech ?? dictation)?.identifier(.bcp47), list.contains(match) {
                return match
            }
        }
        let language = Locale(identifier: id).language.languageCode
        return list.first { Locale(identifier: $0).language.languageCode == language }
            ?? (list.contains("en-US") ? "en-US" : list.first ?? id)
    }

    /// 앱 언어와 이 기기의 지역으로 정한 기본 받아쓰기 언어. 예: 폴란드어 앱 → "pl-PL"
    static var defaultLanguage: String {
        let app = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        let region = Locale.current.region ?? app.region
        return Locale(languageCode: app.language.languageCode, languageRegion: region).identifier(.bcp47)
    }

    /// - Parameter onProgress: 0...1 진행률 (알 수 있을 때만)
    static func transcribe(
        url: URL,
        localeID: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TranscriptSegment] {
        let locale = Locale(identifier: localeID)
        if #available(iOS 26.0, visionOS 26.0, *), SpeechTranscriber.isAvailable {
            return try await transcribeWithAnalyzer(url: url, locale: locale, onProgress: onProgress)
        }
        return try await transcribeWithRecognizer(url: url, locale: locale)
    }

    // MARK: - iOS 26+: SpeechAnalyzer

    /// 긴 녹음에 맞춘 `SpeechTranscriber`를 먼저 쓰고, 그 모델에 없는 언어(폴란드어 등)는
    /// 더 많은 언어를 아는 `DictationTranscriber`로 받아쓴다. 둘 다 기기 안에서 돈다.
    @available(iOS 26.0, visionOS 26.0, *)
    private static func transcribeWithAnalyzer(
        url: URL,
        locale: Locale,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TranscriptSegment] {
        if let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            let module = SpeechTranscriber(
                locale: supported,
                transcriptionOptions: [],
                reportingOptions: [],
                attributeOptions: [.audioTimeRange]
            )
            return try await analyze(url: url, module: module) { total in
                try await words(from: module.results.map { ($0.text, $0.range) }, total: total, onProgress: onProgress)
            }
        }
        if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            let module = DictationTranscriber(
                locale: supported,
                contentHints: [],
                transcriptionOptions: [.punctuation],
                reportingOptions: [],
                attributeOptions: [.audioTimeRange]
            )
            return try await analyze(url: url, module: module) { total in
                try await words(from: module.results.map { ($0.text, $0.range) }, total: total, onProgress: onProgress)
            }
        }
        throw Failure.unsupportedLanguage
    }

    /// 모듈 하나로 파일을 끝까지 들으며, 그동안 `collect`가 결과를 단어로 모은다.
    @available(iOS 26.0, visionOS 26.0, *)
    private static func analyze(
        url: URL,
        module: any SpeechModule,
        collect: @escaping @Sendable (_ total: TimeInterval) async throws -> [Word]
    ) async throws -> [TranscriptSegment] {
        // 언어 모델이 아직 기기에 없으면 내려받는다(처음 한 번).
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }

        let file = try AVAudioFile(forReading: url)
        let total = Double(file.length) / file.processingFormat.sampleRate
        let analyzer = SpeechAnalyzer(modules: [module])
        let collector = Task { try await collect(total) }

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
        return group(try await collector.value)
    }

    /// 받아쓰기 결과(글 · 시간)를 단어 단위로 편다.
    @available(iOS 26.0, visionOS 26.0, *)
    private static func words<Results: AsyncSequence>(
        from results: Results,
        total: TimeInterval,
        onProgress: @Sendable (Double) -> Void
    ) async throws -> [Word] where Results.Element == (AttributedString, CMTimeRange) {
        var words: [Word] = []
        for try await (text, range) in results {
            let end = range.end.seconds
            if total > 0, end.isFinite { onProgress(min(1, end / total)) }
            // 결과 하나가 여러 문장(수십 초)일 수 있어, 단어마다 붙은 시간으로 다시 나눈다.
            var runWords: [Word] = []
            for run in text.runs {
                let piece = String(text[run.range].characters)
                guard let time = run.audioTimeRange, time.start.seconds.isFinite else { continue }
                runWords.append(Word(text: piece, start: time.start.seconds, end: time.end.seconds))
            }
            if runWords.isEmpty {
                let start = range.start.seconds
                runWords = [Word(
                    text: String(text.characters),
                    start: start.isFinite ? start : 0,
                    end: end.isFinite ? end : 0
                )]
            }
            words += runWords
        }
        return words
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
