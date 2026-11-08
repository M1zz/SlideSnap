import AVFoundation
import Combine

/// 오디오 세션을 켜고 끄는 일. 오래 걸릴 수 있어(다른 앱 소리를 멈추게 하는 동안 막힌다) 메인 스레드에서 하지 않는다.
/// 한 줄 대기열이라 켜기 · 끄기 순서가 뒤바뀌지 않는다.
/// iOS 27 의 `activate(options:)` 비동기 API 를 쓰지 않는 것은 iOS 17 부터 지원해서다.
private enum AudioSessionLine {
    private static let queue = DispatchQueue(label: "com.leeo.slidesnap.audio-session", qos: .userInitiated)

    /// 그 쓰임으로 세션을 켠다. 켜졌으면 true.
    static func activate(_ category: AVAudioSession.Category, options: AVAudioSession.CategoryOptions = []) async -> Bool {
        await withCheckedContinuation { done in
            queue.async {
                let session = AVAudioSession.sharedInstance()
                do {
                    try session.setCategory(category, mode: .spokenAudio, options: options)
                    try session.setActive(true)
                    done.resume(returning: true)
                } catch {
                    done.resume(returning: false)
                }
            }
        }
    }

    /// 세션을 끄고 다른 앱이 소리를 다시 내게 알린다. 기다리지 않는다.
    static func deactivate() {
        queue.async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

/// 녹음을 장표와 함께 듣는 재생기. 새로 녹음하지는 않는다 — 1.0.11 부터 녹음 기능을 뺐고, 전에 녹음해 둔 것만 듣는다.
@MainActor
final class AudioPlayback: ObservableObject {

    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    /// 지금 불러온 녹음 id
    @Published private(set) var recordingID: UUID?

    private var player: AVAudioPlayer?
    private var timer: AnyCancellable?

    /// 녹음을 불러온다. 이미 같은 녹음이면 그대로 둔다.
    func load(_ recording: Recording, url: URL) {
        guard recordingID != recording.id else { return }
        stopTimer()
        player?.stop()
        player = try? AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
        recordingID = player == nil ? nil : recording.id
        duration = player?.duration ?? 0
        currentTime = 0
        isPlaying = false
    }

    func play(from time: TimeInterval? = nil) {
        guard let player else { return }
        if let time { player.currentTime = min(max(0, time), player.duration) }
        isPlaying = true
        currentTime = player.currentTime
        Task { [weak self] in
            _ = await AudioSessionLine.activate(.playback)
            // 세션을 켜는 사이에 멈췄거나 다른 녹음을 불러왔으면 틀지 않는다.
            guard let self, isPlaying, self.player === player else { return }
            player.play()
            timer = Timer.publish(every: 0.25, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in self?.tick() }
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = min(max(0, time), player.duration)
        currentTime = player.currentTime
    }

    func skip(by seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    func stop() {
        player?.stop()
        player = nil
        recordingID = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        stopTimer()
    }

    private func tick() {
        guard let player else { return }
        currentTime = player.currentTime
        if !player.isPlaying {
            isPlaying = false
            stopTimer()
        }
    }

    private func stopTimer() { timer = nil }
}

extension TimeInterval {
    /// "1:05" / "1:02:05" 형태
    var clockText: String {
        let total = Int(self.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
