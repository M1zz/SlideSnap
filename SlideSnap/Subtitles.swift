import Foundation

/// 받아쓴 글을 자막 파일(.srt)로 쓰고, 자막 파일을 받아쓴 글로 읽는다.
/// 읽을 때는 WebVTT(.vtt)도 받는다 — 시각 쓰는 법만 조금 다르다.
enum Subtitles {

    static func srt(from segments: [TranscriptSegment]) -> String {
        segments.enumerated().map { index, segment in
            "\(index + 1)\n\(stamp(segment.start)) --> \(stamp(segment.end))\n\(segment.text)\n"
        }
        .joined(separator: "\n")
    }

    /// 자막 파일의 토막들. 읽을 토막이 하나도 없으면 빈 배열.
    static func segments(from text: String) -> [TranscriptSegment] {
        let lines = text
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var segments: [TranscriptSegment] = []
        var current: TranscriptSegment?

        func close() {
            if let open = current, !open.text.isEmpty { segments.append(open) }
            current = nil
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let (start, end) = timing(trimmed) {
                close()
                current = TranscriptSegment(start: start, end: end, text: "")
            } else if trimmed.isEmpty {
                close()
            } else if var open = current {
                let plain = trimmed.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                open.text += (open.text.isEmpty ? "" : " ") + plain
                current = open
            }
        }
        close()
        return segments.sorted { $0.start < $1.start }
    }

    // MARK: - 시각

    /// 3725.5 → "01:02:05,500"
    private static func stamp(_ seconds: TimeInterval) -> String {
        let ms = Int((max(0, seconds) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }

    /// "00:01:02,500 --> 00:01:05,000" 꼴의 줄이면 (시작, 끝). VTT 뒤에 붙는 위치 설정은 버린다.
    private static func timing(_ line: String) -> (TimeInterval, TimeInterval)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2,
              let start = seconds(parts[0]),
              let endText = parts[1].split(separator: " ", omittingEmptySubsequences: true).first,
              let end = seconds(String(endText)) else { return nil }
        return (start, max(start, end))
    }

    /// "01:02:05,500" · "02:05.500" → 초
    private static func seconds(_ text: String) -> TimeInterval? {
        let fields = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
            .split(separator: ":")
        guard (2...3).contains(fields.count) else { return nil }
        var total: TimeInterval = 0
        for field in fields {
            guard let value = TimeInterval(field) else { return nil }
            total = total * 60 + value
        }
        return total
    }
}
