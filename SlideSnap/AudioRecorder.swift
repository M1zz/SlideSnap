import AVFoundation
import Combine

/// 촬영하는 동안 발표 음성을 녹음한다.
///
/// 장표의 촬영 시각과 녹음 시작 시각으로 "이 장표를 찍던 순간"을 찾으므로, 녹음 파일 안의 시간이
/// 실제 시간과 어긋나지 않게 해야 한다. 그래서 전화 같은 끼어들기가 생기면 이어 붙이지 않고
/// 그때까지를 파일 하나로 끊고, 끼어들기가 끝나면 새 파일로 다시 시작한다.
@MainActor
final class AudioRecorder: ObservableObject {

    @Published private(set) var isRecording = false
    /// 지금 녹음 파일의 경과 시간(초)
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var permissionDenied = false

    /// 파일 하나를 끝낼 때마다 불린다.
    var onFinish: ((Recording) -> Void)?

    private let directory: URL
    private var recorder: AVAudioRecorder?
    private var current: (id: UUID, file: String, startedAt: Date)?
    private var timer: AnyCancellable?
    private var interruptionObserver: NSObjectProtocol?
    /// 끼어들기로 멈췄고, 끝나면 다시 녹음해야 하는지
    private var resumeAfterInterruption = false

    /// 이보다 짧은 녹음은 실수로 보고 버린다.
    private static let minimumDuration: TimeInterval = 2

    /// Documents/Audio — Store.audioDirectoryURL 과 같은 곳
    nonisolated static var defaultDirectory: URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    init(directory: URL = AudioRecorder.defaultDirectory) {
        self.directory = directory
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let type = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            MainActor.assumeIsolated { self?.handleInterruption(type) }
        }
    }

    deinit {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
    }

    // MARK: - 시작 / 끝

    func start() {
        guard !isRecording else { return }
        Task {
            guard await Self.requestPermission() else {
                permissionDenied = true
                return
            }
            permissionDenied = false
            beginFile()
        }
    }

    /// 녹음을 끝내고 파일을 넘긴다.
    func stop() {
        resumeAfterInterruption = false
        finishFile()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func beginFile() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker])
            // 녹음 중에도 자동 촬영 햅틱이 울리게 한다.
            try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            try session.setActive(true)
        } catch {
            return
        }

        let id = UUID()
        let file = "\(id.uuidString).m4a"
        // 말소리 위주라 모노·낮은 비트레이트로 충분하다(1시간 ≈ 14MB).
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 22_050,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]
        guard let recorder = try? AVAudioRecorder(url: directory.appendingPathComponent(file), settings: settings),
              recorder.record() else { return }

        self.recorder = recorder
        current = (id, file, Date())
        elapsed = 0
        isRecording = true
        timer = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, let recorder = self.recorder else { return }
                self.elapsed = recorder.currentTime
            }
    }

    private func finishFile() {
        timer = nil
        guard let recorder, let current else {
            isRecording = false
            return
        }
        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        self.current = nil
        isRecording = false
        elapsed = 0

        let url = directory.appendingPathComponent(current.file)
        guard duration >= Self.minimumDuration else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        onFinish?(Recording(id: current.id, startedAt: current.startedAt, duration: duration, file: current.file))
    }

    private func handleInterruption(_ type: AVAudioSession.InterruptionType?) {
        switch type {
        case .began:
            guard isRecording else { return }
            resumeAfterInterruption = true
            finishFile()
        case .ended:
            guard resumeAfterInterruption else { return }
            resumeAfterInterruption = false
            beginFile()
        default:
            break
        }
    }

    private static func requestPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
    }
}

/// 녹음을 장표와 함께 듣는 재생기.
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
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        if let time { player.currentTime = min(max(0, time), player.duration) }
        player.play()
        isPlaying = true
        currentTime = player.currentTime
        timer = Timer.publish(every: 0.25, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
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
