//
//  AudioRecorder.swift
//  SlideSnap
//
//  촬영하는 동안 발표를 녹음한다. **앱이 앞에 떠 있는 동안만.**
//
//  ⚠️ 백그라운드 오디오(UIBackgroundModes 의 audio)는 쓰지 않는다. 1.0.11 심사에서 그 선언이 지침 2.5.4 에 걸려
//     녹음을 통째로 뺐었다(04c6654). 그래서 앱이 뒤로 가면 그때까지를 파일 하나로 끊고, 돌아오면 새 파일로 잇는다.
//     녹음 중에는 화면이 저절로 꺼지지 않게 해서, 카메라를 세워 둔 채 강의 내내 녹음이 이어지게 한다.
//     Info.plist 에 audio 를 다시 넣지 말 것.
//

import AVFoundation
import Combine
import UIKit

/// 촬영하는 동안 발표 음성을 녹음한다.
///
/// 장표의 촬영 시각과 녹음 시작 시각으로 "이 장표를 찍던 순간"을 찾으므로, 녹음 파일 안의 시간이
/// 실제 시간과 어긋나지 않게 해야 한다. 그래서 전화 같은 끼어들기가 생기면 이어 붙이지 않고
/// 그때까지를 파일 하나로 끊고, 끼어들기가 끝나면 새 파일로 다시 시작한다. 앱이 뒤로 갔다 올 때도 같다.
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
    private var observers: [NSObjectProtocol] = []
    /// 녹음하려는 중인가 — 시작을 눌렀고 아직 멈추지 않았다. 세션을 켜는 사이에 멈추면 시작하지 않고,
    /// 끼어들기가 끝나면 이 값을 보고 다시 녹음한다.
    private var wantsRecording = false

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
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let type = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            MainActor.assumeIsolated { self?.handleInterruption(type) }
        })
        // 백그라운드 오디오가 없으니 뒤로 가면 녹음이 멎는다. 끊긴 자리를 우리가 먼저 정한다(파일 속 시간이 어긋나지 않게).
        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleInterruption(.began) }
        })
        observers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleInterruption(.ended) }
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: - 시작 / 끝

    func start() {
        guard !wantsRecording else { return }
        wantsRecording = true
        // 화면이 꺼지면 앱이 뒤로 가고 녹음도 멎는다. 녹음하는 동안은 화면을 켜 둔다.
        UIApplication.shared.isIdleTimerDisabled = true
        Task {
            guard await Self.requestPermission() else {
                wantsRecording = false
                UIApplication.shared.isIdleTimerDisabled = false
                permissionDenied = true
                return
            }
            permissionDenied = false
            await beginFile()
        }
    }

    /// 녹음을 끝내고 파일을 넘긴다.
    func stop() {
        wantsRecording = false
        UIApplication.shared.isIdleTimerDisabled = false
        finishFile()
        AudioSessionLine.deactivate()
    }

    private func beginFile() async {
        guard await AudioSessionLine.activate(.playAndRecord, options: [.defaultToSpeaker]),
              wantsRecording, !isRecording else { return }

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
            finishFile()
        case .ended:
            guard wantsRecording, !isRecording else { return }
            Task { await beginFile() }
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
