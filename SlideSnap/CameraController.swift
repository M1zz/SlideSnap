import AVFoundation
import UIKit
import Vision
import CoreImage
import os
import QuartzCore

/// AVFoundation 캡처 세션 관리.
/// 셔터를 누르면 사진을 찍어 UIImage로 전달합니다. 세션은 계속 돌아가므로 연속 촬영이 빠릅니다.
/// 동시에 라이브 프레임을 분석해 장표 사각형을 실시간 감지합니다.
final class CameraController: NSObject, ObservableObject {

    let session = AVCaptureSession()

    @Published var authorizationDenied = false

    /// 실시간으로 감지된 장표 모서리 (0...1 정규화, 왼쪽 위 원점, 프리뷰와 같은 방향)
    @Published var detectedQuad: Quad?
    /// 감지가 여러 프레임 동안 안정적으로 유지되어 "잘 잡힌" 상태인지
    @Published var isLocked = false
    /// 감지에 사용된 프레임의 가로/세로 비율 (프리뷰 오버레이 좌표 변환용)
    @Published var sourceAspect: CGFloat = 3.0 / 4.0

    /// 현재 줌 배율 (1.0 = 확대 없음)
    @Published var zoomFactor: CGFloat = 1.0
    /// 허용되는 최대 줌 배율
    @Published var maxZoomFactor: CGFloat = 1.0

    /// 장표가 바뀌면 자동으로 촬영할지 여부. 사용자의 선택을 앱 전역에 기억한다.
    @Published var autoCaptureEnabled = true {
        didSet {
            autoCaptureFlag = autoCaptureEnabled
            UserDefaults.standard.set(autoCaptureEnabled, forKey: Self.autoCaptureDefaultsKey)
        }
    }
    private static let autoCaptureDefaultsKey = "camera.autoCaptureEnabled"

    /// 자동 촬영 신호. 값이 바뀌면 뷰가 촬영을 실행한다.
    @Published var autoCaptureTick = 0

    override init() {
        super.init()
        // 저장된 사용자 선택을 복원한다(기본값: 켜짐).
        let stored = (UserDefaults.standard.object(forKey: Self.autoCaptureDefaultsKey) as? Bool) ?? true
        autoCaptureEnabled = stored
    }

    private let photoOutput = AVCapturePhotoOutput()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.leeo.slidesnap.camera")
    // 감지가 프리뷰/촬영을 굶기지 않도록 낮은 우선순위로 둡니다.
    private let videoQueue = DispatchQueue(label: "com.leeo.slidesnap.video", qos: .utility)
    private var isConfigured = false
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var videoDevice: AVCaptureDevice?
    private var previewLayerRef: AVCaptureVideoPreviewLayer?
    private var pendingHandlers: [(UIImage) -> Void] = []

    // 시작 지연 진단용 (Console에서 "slidesnap"으로 필터)
    private let log = Logger(subsystem: "com.leeo.slidesnap", category: "camera")
    private var startRequestedAt: CFTimeInterval = 0
    private var didLogFirstFrame = false
    private var shutterAt: CFTimeInterval = 0

    // 라이브 감지 상태 (videoQueue에서만 접근)
    private var frameCounter = 0
    private var smoothedQuad: Quad?
    private var stableFrames = 0
    /// 시작 직후 이 프레임 수만큼은 감지를 건너뛴다(프리뷰가 먼저 뜨도록 워밍업).
    private let warmupFrames = 20

    // 축소 감지용 재사용 자원 (videoQueue에서만 접근)
    private let detectionContext = CIContext(options: [.cacheIntermediates: false])
    private var scaledPool: CVPixelBufferPool?
    private var scaledPoolSize: CGSize = .zero

    // 자동 촬영 상태 (videoQueue에서만 접근)
    private var autoCaptureFlag = true            // autoCaptureEnabled의 스레드 안전 사본
    private var lastAutoCaptureAt: CFTimeInterval = 0
    private let autoCaptureCooldown: CFTimeInterval = 1.2   // 최소 촬영 간격(초) — 전환 중 중복만 방지

    // 자동 촬영 중복 방지용 내용 지문 (videoQueue에서만 접근)
    private var lastCapturedSignature: [Float]?   // 직전에 담은 장표의 저해상 휘도 지문
    private var currentSignature: [Float]?        // 최근 프레임의 지문
    private var autoCapturePending = false        // 자동 촬영 신호를 내고 결과를 기다리는 중
    private let fingerprintEdge = 16              // 지문 해상도 (16×16)
    private var fingerprintPool: CVPixelBufferPool?
    /// 지문이 이 값 이상 다르면 "다른 장표"로 본다 (0~255 휘도, 평균 절대차).
    /// 작을수록 예민(작은 변화도 새 장표로), 클수록 둔감. 필요시 조정.
    private let contentChangeThreshold: Float = 12

    private let rectangleRequest: VNDetectRectanglesRequest = {
        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.3
        request.maximumAspectRatio = 1.0
        request.minimumSize = 0.2
        request.minimumConfidence = 0.6
        request.maximumObservations = 4
        request.quadratureTolerance = 30
        return request
    }()

    /// 감지에 사용할 축소본의 긴 변 길이(px). 작을수록 빠르고, 정규화 좌표라 정확도 손실은 적습니다.
    private let detectionMaxEdge: CGFloat = 512

    // MARK: - 프리뷰 연결

    /// 프리뷰 레이어를 등록하면 RotationCoordinator가 화면 회전을 자동으로 맞춥니다.
    func attachPreview(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayerRef = layer
        rebuildRotationCoordinator()
    }

    /// 메인 스레드에서 호출. device와 previewLayer가 준비되면 코디네이터를 만든다.
    private func rebuildRotationCoordinator() {
        guard let device = videoDevice else { return }
        rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayerRef)
    }

    // MARK: - 시작/종료

    func start() {
        startRequestedAt = CACurrentMediaTime()
        didLogFirstFrame = false
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.authorizationDenied = !granted
                }
                if granted {
                    self?.configureAndStart()
                }
            }
        default:
            authorizationDenied = true
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    private func configureAndStart() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.isConfigured {
                self.session.beginConfiguration()
                self.session.sessionPreset = .photo
                if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                   let input = try? AVCaptureDeviceInput(device: device),
                   self.session.canAddInput(input) {
                    self.session.addInput(input)
                    if self.session.canAddOutput(self.photoOutput) {
                        self.session.addOutput(self.photoOutput)
                        // 컴퓨테이셔널 포토 처리를 줄여 셔터 지연을 낮춥니다(장표 촬영엔 충분).
                        self.photoOutput.maxPhotoQualityPrioritization = .speed
                    }
                    self.videoDataOutput.alwaysDiscardsLateVideoFrames = true
                    self.videoDataOutput.setSampleBufferDelegate(self, queue: self.videoQueue)
                    if self.session.canAddOutput(self.videoDataOutput) {
                        self.session.addOutput(self.videoDataOutput)
                    }
                    self.videoDevice = device
                    self.isConfigured = true
                    // 손떨림·과확대를 막기 위해 8배로 상한을 둡니다.
                    let maxZ = min(device.maxAvailableVideoZoomFactor, 8.0)
                    let currentZoom = device.videoZoomFactor
                    DispatchQueue.main.async {
                        self.rebuildRotationCoordinator()
                        self.maxZoomFactor = maxZ
                        self.zoomFactor = currentZoom
                    }
                }
                self.session.commitConfiguration()
                self.log.info("configure done +\(CACurrentMediaTime() - self.startRequestedAt, format: .fixed(precision: 2))s")
            }
            if self.isConfigured && !self.session.isRunning {
                self.session.startRunning()
                self.log.info("startRunning returned +\(CACurrentMediaTime() - self.startRequestedAt, format: .fixed(precision: 2))s")
            }
        }
    }

    // MARK: - 촬영

    func capturePhoto(_ handler: @escaping (UIImage) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured else { return }
            self.pendingHandlers.append(handler)

            // 기기를 든 방향에 맞춰 사진 회전 정보 설정
            if let connection = self.photoOutput.connection(with: .video),
               let coordinator = self.rotationCoordinator {
                let angle = coordinator.videoRotationAngleForHorizonLevelCapture
                if connection.isVideoRotationAngleSupported(angle) {
                    connection.videoRotationAngle = angle
                }
            }

            let settings = AVCapturePhotoSettings()
            settings.photoQualityPrioritization = .speed
            self.shutterAt = CACurrentMediaTime()
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    // MARK: - 줌

    /// 줌 배율을 설정합니다. 기기가 허용하는 범위(및 8배 상한)로 자동 보정됩니다.
    func setZoom(_ factor: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDevice else { return }
            let upperBound = min(device.maxAvailableVideoZoomFactor, 8.0)
            let clamped = max(device.minAvailableVideoZoomFactor, min(factor, upperBound))
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = clamped
                device.unlockForConfiguration()
            } catch {
                return
            }
            DispatchQueue.main.async { self.zoomFactor = clamped }
        }
    }
}

// MARK: - 사진 캡처 결과

extension CameraController: AVCapturePhotoCaptureDelegate {

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        // 무거운 인코딩(fileDataRepresentation)은 델리게이트 스레드에서 처리해
        // 세션 큐가 다음 촬영을 곧바로 받을 수 있게 합니다.
        let image: UIImage? = {
            guard error == nil, let data = photo.fileDataRepresentation() else { return nil }
            return UIImage(data: data)
        }()
        log.info("photo ready +\(CACurrentMediaTime() - self.shutterAt, format: .fixed(precision: 2))s")

        sessionQueue.async { [weak self] in
            guard let self, !self.pendingHandlers.isEmpty else { return }
            let handler = self.pendingHandlers.removeFirst()
            guard let image else { return }
            DispatchQueue.main.async {
                handler(image)
            }
        }
    }
}

// MARK: - 라이브 프레임 감지

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if !didLogFirstFrame {
            didLogFirstFrame = true
            log.info("first video frame +\(CACurrentMediaTime() - self.startRequestedAt, format: .fixed(precision: 2))s")
        }
        // 프리뷰와 같은 방향으로 프레임을 세워 놓아야 오버레이 좌표가 일치합니다.
        if let coordinator = rotationCoordinator {
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            if connection.isVideoRotationAngleSupported(angle), connection.videoRotationAngle != angle {
                connection.videoRotationAngle = angle
            }
        }

        // 30fps를 다 처리하면 무거우므로 몇 프레임에 한 번만 감지합니다.
        // 시작 직후 몇 프레임은 건너뛰어 프리뷰가 먼저 부드럽게 뜨도록 합니다.
        frameCounter += 1
        guard frameCounter > warmupFrames, frameCounter % 6 == 0 else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        detectRectangle(in: pixelBuffer)
    }

    /// 긴 변이 detectionMaxEdge를 넘으면 재사용 풀 버퍼로 축소해 반환합니다.
    /// 크기가 작으면 nil을 반환해 원본을 그대로 쓰게 합니다.
    private func downscaledBuffer(from pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let w = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let h = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let longEdge = max(w, h)
        guard longEdge > detectionMaxEdge else { return nil }

        let scale = detectionMaxEdge / longEdge
        let dw = Int((w * scale).rounded()), dh = Int((h * scale).rounded())

        if scaledPool == nil || Int(scaledPoolSize.width) != dw || Int(scaledPoolSize.height) != dh {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: dw,
                kCVPixelBufferHeightKey as String: dh,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
            scaledPool = pool
            scaledPoolSize = CGSize(width: dw, height: dh)
        }

        guard let pool = scaledPool else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let outBuffer = out else { return nil }

        let scaled = CIImage(cvPixelBuffer: pixelBuffer)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        detectionContext.render(scaled, to: outBuffer)
        return outBuffer
    }

    private func detectRectangle(in pixelBuffer: CVPixelBuffer) {
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let aspect = height > 0 ? width / height : 0.75

        // 12MP 원본에 바로 감지를 돌리면 무거우므로 긴 변을 512px로 줄여서 감지합니다.
        // 재사용 컨텍스트/버퍼로 렌더링해 매 프레임 리소스를 새로 만들지 않습니다.
        // 정규화 좌표(0...1)는 축소해도 그대로라 오버레이/보정에 영향이 없습니다.
        let target = downscaledBuffer(from: pixelBuffer) ?? pixelBuffer

        // 자동 촬영 중복 방지를 위해 현재 화면의 내용 지문을 갱신한다.
        currentSignature = makeSignature(from: target)

        let handler = VNImageRequestHandler(cvPixelBuffer: target, orientation: .up, options: [:])
        try? handler.perform([rectangleRequest])

        func score(_ o: VNRectangleObservation) -> CGFloat {
            CGFloat(o.confidence) * o.boundingBox.width * o.boundingBox.height
        }

        guard let observations = rectangleRequest.results,
              let best = observations.max(by: { score($0) < score($1) }) else {
            publish(nil, aspect: aspect)
            return
        }

        // Vision은 왼쪽 아래 원점 → 왼쪽 위 원점으로 변환
        func flip(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: 1 - p.y) }
        let quad = Quad(
            topLeft: flip(best.topLeft),
            topRight: flip(best.topRight),
            bottomRight: flip(best.bottomRight),
            bottomLeft: flip(best.bottomLeft)
        )
        publish(quad, aspect: aspect)
    }

    /// 지터를 줄이도록 부드럽게 이어 붙이고, 여러 프레임 안정되면 잠금(lock) 상태로 표시합니다.
    /// 잠금이 유지되는 동안 매 감지 주기에 자동 촬영 여부를 판단합니다(실제 촬영은
    /// 내용이 직전에 담은 장표와 충분히 다를 때만 — `maybeAutoCapture` 참고).
    private func publish(_ quad: Quad?, aspect: CGFloat) {
        guard let quad else {
            smoothedQuad = nil
            stableFrames = 0
            DispatchQueue.main.async {
                self.detectedQuad = nil
                self.isLocked = false
            }
            return
        }

        let smoothed: Quad
        if let prev = smoothedQuad {
            smoothed = Self.lerp(prev, quad, 0.45)
            stableFrames = Self.maxCornerDelta(prev, quad) < 0.045 ? stableFrames + 1 : 0
        } else {
            smoothed = quad
            stableFrames = 0
        }
        smoothedQuad = smoothed
        let locked = stableFrames >= 3

        DispatchQueue.main.async {
            self.sourceAspect = aspect
            self.detectedQuad = smoothed
            self.isLocked = locked
        }

        if locked {
            maybeAutoCapture()
        }
    }

    /// 잠금 상태에서, 직전에 담은 장표와 내용이 충분히 다를 때만 자동 촬영 신호를 낸다.
    /// - 같은 장표를 계속 비춰도 지문이 비슷하므로 재촬영하지 않는다(스팸 방지).
    /// - 화면(프레임)은 고정이고 장표 내용만 바뀌는 상황에서도 지문 차이로 새로 담는다.
    /// - 쿨다운은 전환 순간의 흐릿한 중간 프레임이 중복 촬영되는 것만 막는다.
    private func maybeAutoCapture() {
        // 직전 신호의 결과(저장/버림)를 기다리는 동안은 새로 내지 않는다.
        guard autoCaptureFlag, !autoCapturePending else { return }
        let now = CACurrentMediaTime()
        guard now - lastAutoCaptureAt > autoCaptureCooldown else { return }

        // 첫 장표(기준 지문 없음)는 바로 담고, 이후엔 내용이 바뀌었을 때만 담는다.
        if let last = lastCapturedSignature, let current = currentSignature {
            guard Self.signatureDistance(last, current) > contentChangeThreshold else { return }
        }

        // 기준 지문은 여기서 올리지 않는다. 흐릿해서 버려질 수 있으므로,
        // 실제로 저장에 성공했을 때(finishAutoCapture(saved:true))만 갱신한다.
        autoCapturePending = true
        lastAutoCaptureAt = now
        DispatchQueue.main.async { self.autoCaptureTick &+= 1 }
    }

    /// 자동 촬영 결과를 반영한다.
    /// - saved=true: 이 화면을 기준 지문으로 삼아 같은 장표를 다시 담지 않는다.
    /// - saved=false(흔들림 등으로 버림): 기준을 그대로 두어, 안정되면 다시 담게 한다.
    func finishAutoCapture(saved: Bool) {
        videoQueue.async { [weak self] in
            guard let self else { return }
            self.autoCapturePending = false
            if saved, let current = self.currentSignature {
                self.lastCapturedSignature = current
            }
            self.lastAutoCaptureAt = CACurrentMediaTime()
        }
    }

    /// 수동 촬영 등 외부에서 한 장 담았을 때, 그 화면을 기준 지문으로 삼는다.
    /// (직후 자동 촬영이 같은 장표를 중복으로 담지 않도록)
    func markCaptured() {
        videoQueue.async { [weak self] in
            guard let self else { return }
            self.lastAutoCaptureAt = CACurrentMediaTime()
            if let current = self.currentSignature { self.lastCapturedSignature = current }
        }
    }

    /// 프레임에서 16×16 저해상 휘도 지문을 만든다. 전역 밝기 변화(자동 노출)에 둔감하도록
    /// 평균을 빼서 반환한다. 값이 클수록 밝은 픽셀.
    private func makeSignature(from buffer: CVPixelBuffer) -> [Float]? {
        let edge = fingerprintEdge
        if fingerprintPool == nil {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: edge,
                kCVPixelBufferHeightKey as String: edge,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
            fingerprintPool = pool
        }
        guard let pool = fingerprintPool else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let outBuffer = out else { return nil }

        let w = CGFloat(CVPixelBufferGetWidth(buffer))
        let h = CGFloat(CVPixelBufferGetHeight(buffer))
        guard w > 0, h > 0 else { return nil }
        let scaled = CIImage(cvPixelBuffer: buffer)
            .transformed(by: CGAffineTransform(scaleX: CGFloat(edge) / w, y: CGFloat(edge) / h))
        detectionContext.render(scaled, to: outBuffer)

        CVPixelBufferLockBaseAddress(outBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(outBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(outBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(outBuffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        var lumas = [Float](repeating: 0, count: edge * edge)
        var sum: Float = 0
        for y in 0..<edge {
            let row = ptr + y * bytesPerRow
            for x in 0..<edge {
                let px = row + x * 4          // BGRA
                let l = 0.114 * Float(px[0]) + 0.587 * Float(px[1]) + 0.299 * Float(px[2])
                lumas[y * edge + x] = l
                sum += l
            }
        }
        let mean = sum / Float(edge * edge)
        for i in lumas.indices { lumas[i] -= mean }
        return lumas
    }

    /// 두 지문의 평균 절대차(0~255 휘도 기준). 클수록 다른 화면.
    private static func signatureDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return .greatestFiniteMagnitude }
        var s: Float = 0
        for i in a.indices { s += abs(a[i] - b[i]) }
        return s / Float(a.count)
    }

    // MARK: - Quad 보조 계산

    private static func lerp(_ a: Quad, _ b: Quad, _ t: CGFloat) -> Quad {
        func mix(_ p: CGPoint, _ q: CGPoint) -> CGPoint {
            CGPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t)
        }
        return Quad(
            topLeft: mix(a.topLeft, b.topLeft),
            topRight: mix(a.topRight, b.topRight),
            bottomRight: mix(a.bottomRight, b.bottomRight),
            bottomLeft: mix(a.bottomLeft, b.bottomLeft)
        )
    }

    private static func maxCornerDelta(_ a: Quad, _ b: Quad) -> CGFloat {
        func dist(_ p: CGPoint, _ q: CGPoint) -> CGFloat { hypot(p.x - q.x, p.y - q.y) }
        return max(
            dist(a.topLeft, b.topLeft),
            dist(a.topRight, b.topRight),
            dist(a.bottomRight, b.bottomRight),
            dist(a.bottomLeft, b.bottomLeft)
        )
    }
}
