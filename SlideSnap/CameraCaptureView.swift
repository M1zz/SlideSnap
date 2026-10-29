import SwiftUI
import AVFoundation
import LeeoKit

/// 카메라 프리뷰 레이어를 SwiftUI에서 사용하기 위한 래퍼
struct CameraPreview: UIViewRepresentable {

    let camera: CameraController

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = camera.session
        view.previewLayer.videoGravity = .resizeAspectFill
        camera.attachPreview(view.previewLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

/// 감지된 장표 모서리를 프리뷰 위에 그리는 오버레이.
/// 잘 잡히면(locked) 초록색으로 "락인"된 느낌을 줍니다.
///
/// 실제 감지는 몇 프레임에 한 번씩 뚝뚝 갱신되지만, 사용자에게는 모서리가
/// 부드럽게 따라가도록 SwiftUI가 네 모서리 좌표를 프레임 단위로 보간한다.
/// 스프링은 새 목표가 와도 움직이던 속도를 이어 가므로, 갱신 사이에 멈칫하지 않는다.
struct DetectionOverlay: View {

    let quad: Quad
    /// 감지 프레임의 가로/세로 비율 (프리뷰는 aspectFill로 채워짐)
    let aspect: CGFloat
    let locked: Bool

    var body: some View {
        let color: Color = locked ? .green : .white

        ZStack {
            // 안쪽 살짝 채우기 + 외곽선
            DetectionQuadShape(quad: quad, aspect: aspect, style: .polygon)
                .fill(color.opacity(locked ? 0.16 : 0.08))
            DetectionQuadShape(quad: quad, aspect: aspect, style: .polygon)
                .stroke(color.opacity(0.9), lineWidth: locked ? 3 : 2)

            // 네 모서리 브래킷 (락인 느낌의 코너 마커)
            DetectionQuadShape(quad: quad, aspect: aspect, style: .brackets)
                .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                .shadow(color: .black.opacity(0.35), radius: 2)
        }
        .animation(.smooth(duration: 0.35), value: quad)
        .animation(.easeInOut(duration: 0.3), value: locked)
    }
}

/// 정규화(0...1, 왼쪽 위 원점) 사각형을 aspectFill 프리뷰 좌표로 그리는 애니메이터블 Shape.
/// `animatableData`로 네 모서리(8개 좌표)를 노출해 SwiftUI가 프레임 단위로 보간한다.
private struct DetectionQuadShape: Shape {
    enum Style { case polygon, brackets }

    var quad: Quad
    var aspect: CGFloat
    var style: Style

    var animatableData: AnimatablePair<
        AnimatablePair<CGPoint.AnimatableData, CGPoint.AnimatableData>,
        AnimatablePair<CGPoint.AnimatableData, CGPoint.AnimatableData>
    > {
        get {
            .init(
                .init(quad.topLeft.animatableData, quad.topRight.animatableData),
                .init(quad.bottomRight.animatableData, quad.bottomLeft.animatableData)
            )
        }
        set {
            quad.topLeft.animatableData = newValue.first.first
            quad.topRight.animatableData = newValue.first.second
            quad.bottomRight.animatableData = newValue.second.first
            quad.bottomLeft.animatableData = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let pts = [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft]
            .map { map($0, in: rect.size) }
        switch style {
        case .polygon:
            return Path { path in
                path.move(to: pts[0])
                path.addLine(to: pts[1])
                path.addLine(to: pts[2])
                path.addLine(to: pts[3])
                path.closeSubpath()
            }
        case .brackets:
            return Path { path in
                for i in 0..<4 {
                    path.move(to: pointFrom(pts[i], toward: pts[(i + 1) % 4]))
                    path.addLine(to: pts[i])
                    path.addLine(to: pointFrom(pts[i], toward: pts[(i + 3) % 4]))
                }
            }
        }
    }

    private func pointFrom(_ from: CGPoint, toward to: CGPoint) -> CGPoint {
        let length: CGFloat = 26
        let dx = to.x - from.x, dy = to.y - from.y
        let m = max(hypot(dx, dy), 0.0001)
        return CGPoint(x: from.x + dx / m * length, y: from.y + dy / m * length)
    }

    /// 정규화 좌표를 aspectFill 기준의 뷰 좌표로 변환
    private func map(_ p: CGPoint, in size: CGSize) -> CGPoint {
        guard size.width > 0, size.height > 0 else { return .zero }
        let viewAspect = size.width / size.height
        var drawW = size.width, drawH = size.height, offX: CGFloat = 0, offY: CGFloat = 0
        if aspect > viewAspect {
            // 이미지가 더 넓다 → 높이를 맞추고 좌우를 자름
            drawH = size.height
            drawW = size.height * aspect
            offX = (size.width - drawW) / 2
        } else {
            drawW = size.width
            drawH = size.width / aspect
            offY = (size.height - drawH) / 2
        }
        return CGPoint(x: offX + p.x * drawW, y: offY + p.y * drawH)
    }
}

/// 전체 화면 촬영 화면.
/// 셔터만 계속 누르면 자동으로 감지·보정되어 발표에 차곡차곡 쌓입니다.
struct CameraCaptureView: View {

    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let presentationID: UUID
    /// 촬영이 한 장이라도 일어나면 부모에게 알린다(빈 발표 삭제 방지 + 그리드 이동 판단).
    var onCapture: (() -> Void)? = nil

    @StateObject private var camera = CameraController()
    @StateObject private var recorder = AudioRecorder()
    /// 촬영하면서 녹음할지(기억됨)
    @AppStorage("camera.recordAudio") private var recordAudio = false
    @State private var showMicDenied = false
    @State private var captureCount = 0
    @State private var processingCount = 0
    @State private var lastThumbnail: UIImage?
    @State private var flashOpacity: Double = 0
    @State private var showBlurHint = false

    /// 방금 담은 장표가 화면에서 썸네일 자리로 줄어들며 날아가는 연출
    @State private var flyingShot: UIImage?
    @State private var flyLanded = false
    @State private var thumbnailFrame: CGRect = .zero

    /// 가장 최근에 담은 장표(촬영 중 메모를 붙일 대상)
    @State private var lastSlideID: UUID?
    @State private var memoTargetID: UUID?
    @State private var memoDraft = ""

    // 줌 제스처가 시작될 때의 기준 배율
    @State private var zoomBaseline: CGFloat = 1.0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if camera.authorizationDenied {
                deniedView
            } else {
                CameraPreview(camera: camera)
                    .ignoresSafeArea()

                ZStack {
                    if let quad = camera.detectedQuad {
                        DetectionOverlay(quad: quad, aspect: camera.sourceAspect, locked: camera.isLocked)
                            .transition(.opacity)
                    }
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .animation(.easeInOut(duration: 0.25), value: camera.detectedQuad == nil)

                // 줌 제스처를 받는 투명 레이어 (버튼들보다 아래에 두어 조작을 방해하지 않음)
                zoomGestureLayer
            }

            Color.white
                .opacity(flashOpacity)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack {
                topBar
                statusLabel
                    .animation(.easeInOut(duration: 0.25), value: camera.detectedQuad == nil)
                Spacer()
                zoomIndicator
                bottomBar
            }

            GeometryReader { proxy in
                flyingShotView(in: proxy.size)
            }
            .allowsHitTesting(false)
        }
        .coordinateSpace(.named(Self.space))
        .statusBarHidden()
        .onAppear {
            camera.start()
            recorder.onFinish = { [store, presentationID] recording in
                store.addRecording(recording, to: presentationID)
            }
            if recordAudio { recorder.start() }
        }
        .onDisappear {
            camera.stop()
            recorder.stop()
        }
        .onChange(of: recorder.elapsed) { _, elapsed in
            // 장표 없이 녹음만 해도 발표로 남긴다.
            if elapsed >= 3 { onCapture?() }
        }
        .onChange(of: recorder.permissionDenied) { _, denied in
            if denied {
                recordAudio = false
                showMicDenied = true
            }
        }
        .alert("방금 찍은 장표에 메모", isPresented: memoAlertShown) {
            TextField("이 장표에 메모 남기기", text: $memoDraft)
            Button("저장") {
                if let memoTargetID {
                    store.setMemo(memoDraft, slideID: memoTargetID, presentationID: presentationID)
                }
            }
            Button("취소", role: .cancel) {}
        }
        .alert("마이크 접근이 허용되지 않았습니다", isPresented: $showMicDenied) {
            Button("설정 열기") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("닫기", role: .cancel) {}
        } message: {
            Text("발표를 녹음하려면 설정에서 마이크 접근을 허용해 주세요.")
        }
        .onChange(of: camera.isLocked) { _, locked in
            if locked {
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                // VoiceOver: 장표가 화면에 잘 잡혔음을 소리로 알린다.
                AccessibilityNotification.Announcement(camera.autoCaptureEnabled
                    ? String(localized: "장표를 잘 잡았어요 · 자동으로 담는 중")
                    : String(localized: "장표를 잘 잡았어요 · 지금 찍으세요")).post()
            }
        }
        .onChange(of: camera.autoCaptureTick) { _, _ in
            capture(auto: true)   // 장표가 바뀌어 초록(락인)되면 자동으로 촬영
        }
        .overlay(alignment: .top) { blurHintLabel }
    }

    /// 흔들린 자동 촬영을 건너뛰었을 때 잠깐 보여주는 안내.
    @ViewBuilder
    private var blurHintLabel: some View {
        if showBlurHint {
            HStack(spacing: 6) {
                Image(systemName: "wind")
                Text("흔들린 컷은 건너뛰었어요")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.black.opacity(0.6), in: Capsule())
            .padding(.top, 60)
            .transition(.opacity)
        }
    }

    // MARK: - 감지 상태 안내

    @ViewBuilder
    private var statusLabel: some View {
        if !camera.authorizationDenied, camera.detectedQuad != nil {
            let locked = camera.isLocked
            let lockedText = camera.autoCaptureEnabled
                ? String(localized: "장표를 잘 잡았어요 · 자동으로 담는 중")
                : String(localized: "장표를 잘 잡았어요 · 지금 찍으세요")
            HStack(spacing: 6) {
                Image(systemName: locked ? "checkmark.circle.fill" : "viewfinder")
                Text(locked ? lockedText : String(localized: "장표를 화면에 맞춰 주세요"))
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background((locked ? Self.lockedGreen : Color.black.opacity(0.5)), in: Capsule())
            .padding(.top, 4)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.3), value: locked)
            .accessibilityElement(children: .combine)
        }
    }

    /// 흰 글씨를 얹어도 읽히는 진한 초록(기본 초록은 흰 글씨와 대비가 모자라다).
    private static let lockedGreen = Color(red: 0.11, green: 0.52, blue: 0.24)

    // MARK: - 줌

    /// 두 손가락 핀치 + 한 손가락 세로 스와이프로 줌을 조작하는 투명 레이어.
    /// VoiceOver 에서는 위아래로 쓸어 줌을 조절하는 하나의 요소가 된다.
    private var zoomGestureLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            .ignoresSafeArea()
            .gesture(pinchGesture)
            .simultaneousGesture(swipeZoomGesture)
            .accessibilityElement()
            .accessibilityLabel("줌")
            .accessibilityValue(String(format: "%.1f×", camera.zoomFactor))
            .accessibilityAdjustableAction { direction in
                let step = max(camera.maxZoomFactor - 1, 1) / 8
                switch direction {
                case .increment: camera.setZoom(camera.zoomFactor + step)
                case .decrement: camera.setZoom(camera.zoomFactor - step)
                @unknown default: break
                }
                zoomBaseline = camera.zoomFactor
            }
    }

    /// 두 손가락으로 벌리면 확대, 오므리면 축소
    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                camera.setZoom(zoomBaseline * value.magnification)
            }
            .onEnded { _ in
                zoomBaseline = camera.zoomFactor
            }
    }

    /// 한 손가락으로 위로 스와이프하면 확대, 아래로 스와이프하면 축소
    private var swipeZoomGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                // 화면 높이의 절반을 스와이프하면 최소↔최대 줌을 오가도록 매핑
                let range = max(camera.maxZoomFactor - 1, 0.0001)
                let delta = -value.translation.height / 250 * range
                camera.setZoom(zoomBaseline + delta)
            }
            .onEnded { _ in
                zoomBaseline = camera.zoomFactor
            }
    }

    /// 현재 줌 배율 표시 (확대 중일 때만)
    @ViewBuilder
    private var zoomIndicator: some View {
        if camera.zoomFactor > 1.05 {
            Text(String(format: "%.1f×", camera.zoomFactor))
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.5), in: Capsule())
                .padding(.bottom, 12)
                .transition(.opacity)
                .animation(.easeOut(duration: 0.15), value: camera.zoomFactor)
        }
    }

    // MARK: - 상단 바

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Text("완료")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.4), in: Capsule())
            }
            Spacer()
            if processingCount > 0 {
                ProgressView()
                    .tint(.white)
                    .padding(.trailing, 8)
            }
            recordButton
            Button {
                camera.autoCaptureEnabled.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: camera.autoCaptureEnabled ? "bolt.fill" : "bolt.slash")
                    Text("자동")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(camera.autoCaptureEnabled ? Color.green : .white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.black.opacity(0.4), in: Capsule())
            }
            .accessibilityLabel("자동 촬영")
            .accessibilityValue(camera.autoCaptureEnabled ? Text("켬") : Text("끔"))
        }
        .padding()
        // 프리뷰를 가리지 않도록 촬영 단추 글씨는 너무 커지지 않게 둔다.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    /// 녹음 켜기/끄기. 녹음 중이면 빨간 점과 경과 시간을 보여 준다.
    private var recordButton: some View {
        Button {
            recordAudio.toggle()
            if recordAudio {
                recorder.start()
            } else {
                recorder.stop()
            }
        } label: {
            HStack(spacing: 5) {
                if recorder.isRecording {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                    Text(recorder.elapsed.clockText)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                } else {
                    Image(systemName: recordAudio ? "mic.fill" : "mic.slash")
                    Text("녹음")
                        .font(.subheadline.weight(.semibold))
                }
            }
            .foregroundStyle(recorder.isRecording ? Color.white : (recordAudio ? Color.red : .white))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(recorder.isRecording ? Color.red.opacity(0.75) : Color.black.opacity(0.4), in: Capsule())
        }
        .accessibilityLabel(recorder.isRecording ? Text("녹음 중지") : Text("녹음 시작"))
        .accessibilityValue(recorder.isRecording ? recorder.elapsed.clockText : "")
    }

    // MARK: - 하단 바

    private var bottomBar: some View {
        HStack {
            Button {
                dismiss()   // 앨범 탭 → 카메라를 닫으면 촬영한 장표 그리드로 이동
            } label: {
                thumbnailView
                    .frame(width: 64, height: 64)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { thumbnailFrame = $0 }
            }
            .disabled(captureCount == 0)
            .accessibilityLabel("촬영한 장표 보기")
            .accessibilityValue(captureCount > 0 ? Text("\(captureCount)장") : Text(""))

            Spacer()

            Button {
                capture()
            } label: {
                ZStack {
                    Circle()
                        .stroke(camera.isLocked ? Color.green : .white, lineWidth: 4)
                        .frame(width: 76, height: 76)
                    Circle()
                        .fill(.white)
                        .frame(width: 62, height: 62)
                }
                .animation(.easeOut(duration: 0.15), value: camera.isLocked)
            }
            .disabled(camera.authorizationDenied)
            .accessibilityLabel("촬영하기")

            Spacer()

            memoButton
                .frame(width: 64, height: 64)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 28)
    }

    /// 방금 담은 장표에 바로 메모를 붙인다(촬영을 멈추지 않고).
    private var memoButton: some View {
        Button {
            guard let lastSlideID else { return }
            memoTargetID = lastSlideID
            memoDraft = store.presentation(presentationID)?.slides.first { $0.id == lastSlideID }?.memo ?? ""
        } label: {
            Image(systemName: "note.text.badge.plus")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(.black.opacity(0.4), in: Circle())
        }
        .opacity(lastSlideID == nil ? 0 : 1)
        .disabled(lastSlideID == nil)
        .animation(.easeOut(duration: 0.25), value: lastSlideID == nil)
        .accessibilityLabel("방금 찍은 장표에 메모")
    }

    private var memoAlertShown: Binding<Bool> {
        Binding(get: { memoTargetID != nil }, set: { if !$0 { memoTargetID = nil } })
    }

    private static let space = "capture"

    /// 담은 사진이 화면 가운데에서 썸네일 자리로 줄어들며 들어간다.
    @ViewBuilder
    private func flyingShotView(in size: CGSize) -> some View {
        if let shot = flyingShot, shot.size.width > 0 {
            let width = size.width - 48
            let height = min(width * shot.size.height / shot.size.width, size.height * 0.7)
            let start = CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
            let rect = flyLanded ? thumbnailFrame : start
            Image(uiImage: shot)
                .resizable()
                .scaledToFill()
                .frame(width: rect.width, height: rect.height)
                .clipShape(RoundedRectangle(cornerRadius: flyLanded ? 10 : 18))
                .accessibilityHidden(true)
                .shadow(color: .black.opacity(0.35), radius: flyLanded ? 2 : 16)
                .position(x: rect.midX, y: rect.midY)
        }
    }

    private func fly(_ shot: UIImage) {
        // 동작 줄이기: 날아가는 연출 없이 썸네일만 바꾼다.
        if reduceMotion {
            lastThumbnail = shot
            return
        }
        flyLanded = false
        flyingShot = shot
        // 시작 위치에 한 번 그린 다음 날려 보낸다.
        DispatchQueue.main.async {
            withAnimation(.smooth(duration: 0.5)) {
                flyLanded = true
            } completion: {
                lastThumbnail = shot
                if flyingShot === shot { flyingShot = nil }
            }
        }
    }

    private var thumbnailView: some View {
        ZStack(alignment: .topTrailing) {
            if let lastThumbnail {
                Image(uiImage: lastThumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(.white.opacity(0.6), lineWidth: 1)
                    )
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.black.opacity(0.3))
                    .frame(width: 64, height: 64)
            }

            if captureCount > 0 {
                Text("\(captureCount)")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.accentColor, in: Capsule())
                    .offset(x: 8, y: -8)
            }
        }
    }

    private var deniedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.slash.fill")
                .font(.largeTitle)
            Text("카메라 접근이 허용되지 않았습니다.\n설정에서 카메라 접근을 허용해 주세요.")
                .multilineTextAlignment(.center)
            Button("설정 열기") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .foregroundStyle(.white)
        .padding()
    }

    // MARK: - 촬영

    /// - Parameter auto: 자동 촬영이면 흔들린(흐릿한) 컷을 걸러내고, 결과를 카메라에 알린다.
    ///   수동 촬영은 사용자의 의도이므로 걸러내지 않고 그대로 담는다.
    private func capture(auto: Bool = false) {
        // 눈부시지 않게 살짝 밝아졌다가 천천히 돌아온다(동작 줄이기면 번쩍임 없이).
        if !reduceMotion {
            withAnimation(.easeOut(duration: 0.08)) { flashOpacity = 0.35 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                withAnimation(.easeOut(duration: 0.35)) { flashOpacity = 0 }
            }
        }

        // 셔터를 누른 순간 잡혀 있던 모서리로 폅니다(화면 테두리는 늦게 따라오므로 감지값 그대로).
        let quadAtCapture = camera.latestQuad
        // 수동 촬영은 방금 담은 화면을 자동 촬영의 기준으로 삼아 같은 장표 중복을 막는다.
        if !auto { camera.markCaptured() }

        processingCount += 1
        // 녹음 속 위치를 맞추려고 처리 시각이 아닌 셔터를 누른 순간을 장표 시각으로 쓴다.
        let shotAt = Date()
        camera.capturePhoto { image in
            Task { @MainActor in
                // 자동 촬영이면 흐릿한 컷은 버린다(락인 상태라 대부분 선명하지만 전환 순간을 거른다).
                if auto {
                    let blurry = await Task.detached(priority: .userInitiated) { image.isBlurry() }.value
                    if blurry {
                        processingCount = max(0, processingCount - 1)
                        camera.finishAutoCapture(saved: false)   // 기준 유지 → 안정되면 다시 시도
                        flashBlurHint()
                        return
                    }
                    camera.finishAutoCapture(saved: true)
                }

                // 즉시 피드백: 사진이 도착하자마자 카운트를 올리고 빠른 미리보기를 띄운다.
                captureCount += 1
                onCapture?()
                // VoiceOver: 화면을 볼 수 없어도 몇 장 담겼는지 알 수 있게.
                AccessibilityNotification.Announcement(String(localized: "지금까지 장표 \(captureCount)장을 담았어요")).post()
                // 촬영은 핵심 행동 — 로컬 카운트만 올린다(사용 통계 스냅샷의 eventCount에 반영).
                LeeoEngagement.shared.registerSignificantEvent()
                Task.detached(priority: .userInitiated) {
                    let quick = image.downsampled(maxDimension: 600)
                    await MainActor.run { fly(quick) }
                }

                // 무거운 감지·보정·저장은 뒤에서 진행.
                if let slideID = await store.addSlide(image: image, to: presentationID, detectedQuad: quadAtCapture, createdAt: shotAt) {
                    lastSlideID = slideID
                }
                processingCount = max(0, processingCount - 1)
            }
        }
    }

    private func flashBlurHint() {
        AccessibilityNotification.Announcement(String(localized: "흔들린 컷은 건너뛰었어요")).post()
        withAnimation(.easeOut(duration: 0.2)) { showBlurHint = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation(.easeOut(duration: 0.3)) { showBlurHint = false }
        }
    }
}
