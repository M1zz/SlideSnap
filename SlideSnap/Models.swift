import Foundation
import CoreGraphics

/// 이미지 안에서 슬라이드 영역을 나타내는 사각형.
/// 모든 좌표는 0...1 로 정규화되어 있고, 원점은 왼쪽 위(UIKit 좌표계)입니다.
struct Quad: Codable, Equatable {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomRight: CGPoint
    var bottomLeft: CGPoint

    /// 이미지 전체 영역
    static let full = Quad(
        topLeft: CGPoint(x: 0, y: 0),
        topRight: CGPoint(x: 1, y: 0),
        bottomRight: CGPoint(x: 1, y: 1),
        bottomLeft: CGPoint(x: 0, y: 1)
    )

    /// 수동 조정 시작용 기본 사각형 (10% 안쪽)
    static let defaultInset = Quad(
        topLeft: CGPoint(x: 0.1, y: 0.1),
        topRight: CGPoint(x: 0.9, y: 0.1),
        bottomRight: CGPoint(x: 0.9, y: 0.9),
        bottomLeft: CGPoint(x: 0.1, y: 0.9)
    )
}

/// 촬영한 장표 한 장
struct Slide: Identifiable, Codable, Equatable {
    let id: UUID
    var createdAt: Date
    /// 원본 사진 파일명 (Images 디렉터리 기준)
    var originalFile: String
    /// 원근 보정된 사진 파일명
    var correctedFile: String
    /// 그리드용 썸네일 파일명
    var thumbFile: String
    /// 보정에 사용된 모서리 좌표 (nil이면 보정 없이 원본 그대로)
    var corners: Quad?
    /// 자동 감지로 보정되었는지 여부
    var autoDetected: Bool
    /// OCR로 인식한 장표 텍스트. nil = 아직 인식 전(기존 데이터), "" = 인식했으나 글자 없음.
    var recognizedText: String?
    /// 가독성 보정(대비·그림자 보정)을 적용했는지 여부. nil/false = 미적용(기존 데이터 호환).
    var enhanced: Bool?
    /// 가독성 보정본 파일명. 보정을 켰을 때 생성됩니다.
    var enhancedFile: String?

    /// 가독성 보정이 켜져 있는지.
    var isEnhanced: Bool { enhanced == true && enhancedFile != nil }
}

/// 받아쓰기 결과 한 토막. 시각은 녹음 시작부터의 초.
struct TranscriptSegment: Codable, Equatable, Sendable {
    var start: TimeInterval
    var end: TimeInterval
    var text: String
}

/// 촬영하면서 녹음한 음성 파일 하나.
/// 장표의 `createdAt`이 `startedAt ..< startedAt + duration` 안에 있으면 그 장표를 찍던 순간의 소리가 여기 들어 있다.
struct Recording: Identifiable, Codable, Equatable {
    let id: UUID
    var startedAt: Date
    var duration: TimeInterval
    /// 음성 파일명 (Audio 디렉터리 기준)
    var file: String
    /// 받아쓰기 결과. nil = 아직 받아쓰지 않음.
    var transcript: [TranscriptSegment]?
    /// 받아쓰기에 쓴 언어 (예: "ko-KR")
    var transcriptLocale: String?

    var endedAt: Date { startedAt.addingTimeInterval(duration) }

    /// 해당 시각이 이 녹음 구간 안인지. 처리 지연을 감안해 끝을 조금 넉넉히 본다.
    func covers(_ date: Date) -> Bool {
        date >= startedAt.addingTimeInterval(-1) && date <= endedAt.addingTimeInterval(1)
    }

    /// 녹음 안에서의 위치(초)
    func offset(of date: Date) -> TimeInterval {
        min(max(0, date.timeIntervalSince(startedAt)), duration)
    }
}

/// AI가 만든 발표 요약.
struct PresentationSummary: Codable, Equatable {
    var overview: String
    var keyPoints: [String]
    var keywords: [String]
    var generatedAt: Date
}

/// 발표(세션) 하나 — 장표들이 순서대로 담긴다
struct Presentation: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var createdAt: Date
    var slides: [Slide]
    /// 촬영하며 녹음한 음성들 (nil/빈 배열 = 녹음 없음, 기존 데이터 호환)
    var recordings: [Recording]?
    /// AI 요약 (nil = 아직 만들지 않음)
    var summary: PresentationSummary?

    var allRecordings: [Recording] { recordings ?? [] }

    /// 장표를 찍던 순간이 담긴 녹음과 그 안의 위치.
    func audioPosition(for slide: Slide) -> (recording: Recording, offset: TimeInterval)? {
        guard let recording = allRecordings.first(where: { $0.covers(slide.createdAt) }) else { return nil }
        return (recording, recording.offset(of: slide.createdAt))
    }

    /// 녹음 안에서 이 장표가 차지하는 구간(초).
    /// 이 장표를 찍은 때부터 같은 녹음 안에서 다음으로 찍은 장표 직전까지. 녹음 속 첫 장표는 녹음 시작부터 잡는다.
    func audioRange(for slide: Slide) -> (recording: Recording, range: ClosedRange<TimeInterval>)? {
        guard let (recording, offset) = audioPosition(for: slide) else { return nil }
        let times = slides
            .filter { recording.covers($0.createdAt) }
            .map { recording.offset(of: $0.createdAt) }
            .sorted()
        let isFirst = times.first.map { offset <= $0 } ?? true
        let start = isFirst ? 0 : offset
        let end = times.first(where: { $0 > offset }) ?? recording.duration
        return (recording, start...max(start, end))
    }

    /// 이 장표를 보여 주던 동안 녹음에서 받아쓴 말.
    func transcriptText(for slide: Slide) -> String? {
        guard let (recording, range) = audioRange(for: slide),
              let segments = recording.transcript else { return nil }
        let text = segments
            .filter { range.contains(($0.start + $0.end) / 2) }
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// 녹음 위치(초)에 해당하는 장표 id. 재생 중 장표를 따라 넘길 때 쓴다.
    func slideID(at time: TimeInterval, in recording: Recording) -> UUID? {
        let candidates = slides
            .filter { recording.covers($0.createdAt) }
            .map { (id: $0.id, t: recording.offset(of: $0.createdAt)) }
            .sorted { $0.t < $1.t }
        guard let first = candidates.first else { return nil }
        return candidates.last(where: { $0.t <= time })?.id ?? first.id
    }
}
