import SwiftUI

/// 사각형의 네 모서리 식별자
enum Corner: CaseIterable {
    case topLeft, topRight, bottomRight, bottomLeft
}

extension Quad {
    subscript(_ corner: Corner) -> CGPoint {
        get {
            switch corner {
            case .topLeft: return topLeft
            case .topRight: return topRight
            case .bottomRight: return bottomRight
            case .bottomLeft: return bottomLeft
            }
        }
        set {
            switch corner {
            case .topLeft: topLeft = newValue
            case .topRight: topRight = newValue
            case .bottomRight: bottomRight = newValue
            case .bottomLeft: bottomLeft = newValue
            }
        }
    }
}

/// 원본 사진 위에 노란 사각형을 겹쳐 보여주고,
/// 네 모서리를 드래그해서 보정 영역을 직접 지정하는 화면입니다.
struct CornerAdjustView: View {

    let image: UIImage
    let onApply: (Quad?) -> Void

    @State private var quad: Quad
    @Environment(\.dismiss) private var dismiss

    init(image: UIImage, initialQuad: Quad, onApply: @escaping (Quad?) -> Void) {
        self.image = image
        self.onApply = onApply
        self._quad = State(initialValue: initialQuad)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let fitted = Self.fittedRect(imageSize: image.size, in: geometry.size)

                ZStack {
                    Color.black.ignoresSafeArea()

                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)

                    QuadShape(quad: quad, rect: fitted)
                        .fill(Color.yellow.opacity(0.12))

                    QuadShape(quad: quad, rect: fitted)
                        .stroke(Color.yellow, lineWidth: 2)

                    ForEach(Corner.allCases, id: \.self) { corner in
                        handle(corner, in: fitted)
                    }
                }
                .coordinateSpace(name: "canvas")
            }
            .navigationTitle("모서리 조정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("적용") {
                        onApply(quad)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("자동 감지") {
                        if let detected = ImageProcessor.detectSlideQuad(in: image) {
                            withAnimation(.easeInOut(duration: 0.2)) { quad = detected }
                        }
                    }
                    Spacer()
                    Button("전체 영역") {
                        withAnimation(.easeInOut(duration: 0.2)) { quad = .full }
                    }
                }
            }
        }
    }

    // MARK: - 모서리 핸들

    private func handle(_ corner: Corner, in rect: CGRect) -> some View {
        let point = Self.viewPoint(quad[corner], in: rect)
        return ZStack {
            Circle()
                .fill(Color.yellow.opacity(0.35))
                .frame(width: 44, height: 44)
            Circle()
                .fill(Color.yellow)
                .frame(width: 18, height: 18)
                .overlay(Circle().stroke(.white, lineWidth: 2))
        }
        .position(point)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
                .onChanged { value in
                    quad[corner] = Self.normalizedPoint(value.location, in: rect)
                }
        )
    }

    // MARK: - 좌표 변환

    static func fittedRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    static func viewPoint(_ normalized: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + normalized.x * rect.width,
                y: rect.minY + normalized.y * rect.height)
    }

    static func normalizedPoint(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        guard rect.width > 0, rect.height > 0 else { return .zero }
        let x = (point.x - rect.minX) / rect.width
        let y = (point.y - rect.minY) / rect.height
        return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }
}

/// 네 모서리를 잇는 사각형 셰이프
struct QuadShape: Shape {
    let quad: Quad
    let rect: CGRect

    func path(in _: CGRect) -> Path {
        var path = Path()
        path.move(to: CornerAdjustView.viewPoint(quad.topLeft, in: rect))
        path.addLine(to: CornerAdjustView.viewPoint(quad.topRight, in: rect))
        path.addLine(to: CornerAdjustView.viewPoint(quad.bottomRight, in: rect))
        path.addLine(to: CornerAdjustView.viewPoint(quad.bottomLeft, in: rect))
        path.closeSubpath()
        return path
    }
}
