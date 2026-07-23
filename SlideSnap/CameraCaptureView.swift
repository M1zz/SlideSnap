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
/// 느리고 부드럽게 따라가도록 SwiftUI가 네 모서리 좌표를 프레임 단위로 보간한다.
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
        // 감지 값이 바뀔 때마다 모서리를 부드럽게 보간(느린 트레일링 모션).
        .animation(.easeOut(duration: 0.35), value: quad)
        .animation(.easeOut(duration: 0.2), value: locked)
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

    let presentationID: UUID
    /// 촬영이 한 장이라도 일어나면 부모에게 알린다(빈 발표 삭제 방지 + 그리드 이동 판단).
    var onCapture: (() -> Void)? = nil

    @StateObject private var camera = CameraController()
    @State private var captureCount = 0
    @State private var processingCount = 0
    @State private var lastThumbnail: UIImage?
    @State private var flashOpacity: Double = 0
    @State private var showBlurHint = false

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

                if let quad = camera.detectedQuad {
                    DetectionOverlay(quad: quad, aspect: camera.sourceAspect, locked: camera.isLocked)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }

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
                Spacer()
                zoomIndicator
                bottomBar
            }
        }
        .statusBarHidden()
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
        .onChange(of: camera.isLocked) { _, locked in
            if locked {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
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
            let lockedText = camera.autoCaptureEnabled ? "장표를 잘 잡았어요 · 자동으로 담는 중" : "장표를 잘 잡았어요 · 지금 찍으세요"
            HStack(spacing: 6) {
                Image(systemName: locked ? "checkmark.circle.fill" : "viewfinder")
                Text(locked ? lockedText : "장표를 화면에 맞춰 주세요")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background((locked ? Color.green : Color.black.opacity(0.5)), in: Capsule())
            .padding(.top, 4)
            .transition(.opacity)
            .animation(.easeOut(duration: 0.2), value: locked)
        }
    }

    // MARK: - 줌

    /// 두 손가락 핀치 + 한 손가락 세로 스와이프로 줌을 조작하는 투명 레이어
    private var zoomGestureLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            .ignoresSafeArea()
            .gesture(pinchGesture)
            .simultaneousGesture(swipeZoomGesture)
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
        }
        .padding()
    }

    // MARK: - 하단 바

    private var bottomBar: some View {
        HStack {
            Button {
                dismiss()   // 앨범 탭 → 카메라를 닫으면 촬영한 장표 그리드로 이동
            } label: {
                thumbnailView
                    .frame(width: 64, height: 64)
            }
            .disabled(captureCount == 0)

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

            Spacer()

            Color.clear
                .frame(width: 64, height: 64)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 28)
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
        withAnimation(.easeIn(duration: 0.05)) { flashOpacity = 0.7 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.easeOut(duration: 0.2)) { flashOpacity = 0 }
        }

        // 셔터를 누른 순간 화면에서 잡혀 있던 모서리를 그대로 사용해 폅니다.
        let quadAtCapture = camera.detectedQuad
        // 수동 촬영은 방금 담은 화면을 자동 촬영의 기준으로 삼아 같은 장표 중복을 막는다.
        if !auto { camera.markCaptured() }

        processingCount += 1
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
                // 촬영은 핵심 행동 — 로컬 카운트만 올린다(사용 통계 스냅샷의 eventCount에 반영).
                LeeoEngagement.shared.registerSignificantEvent()
                Task.detached(priority: .userInitiated) {
                    let quick = image.downsampled(maxDimension: 160)
                    await MainActor.run { lastThumbnail = quick }
                }

                // 무거운 감지·보정·저장은 뒤에서 진행.
                await store.addSlide(image: image, to: presentationID, detectedQuad: quadAtCapture)
                processingCount = max(0, processingCount - 1)
            }
        }
    }

    private func flashBlurHint() {
        withAnimation(.easeOut(duration: 0.2)) { showBlurHint = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation(.easeOut(duration: 0.3)) { showBlurHint = false }
        }
    }
}
