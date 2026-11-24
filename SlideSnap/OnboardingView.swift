//
//  OnboardingView.swift
//  SlideSnap
//
//  처음 쓰는 사람이 해 본다 — 찍기 · 펴기 · 찾기. 누구나 같은 장면으로.
//  강의실 화면을 손에 든 카메라처럼 비추고, 앱의 감지 테두리가 장표를 잡아 잠그면
//  셔터를 누르거나 — 가만히 있어도 자동 촬영처럼 — 찰칵 찍힌다.
//  그 사진의 모서리 찾기 · 반듯하게 펴기 · 글자 읽기는 앱이 실제로 쓰는 처리 그대로다.
//  글은 큰 제목 한 줄뿐, 나머지는 그림과 움직임이 말한다. 한 장을 해 봐야 다음 단추가 깨어난다(건너뛰기는 늘 있다).
//  발표가 하나도 없는 첫 실행에만 뜬다 (→ PresentationListView.reacting). 끝내면 진짜 카메라가 열린다.
//

#if os(iOS) && !targetEnvironment(macCatalyst)
import SwiftUI
import Vision

struct OnboardingView: View {
    /// 끝났을 때. 마지막 단추로 끝냈으면 true — 이제 진짜로 찍으러 카메라를 연다.
    var onFinish: (_ finished: Bool) -> Void

    @StateObject private var trial = OnboardingTrial()
    @State private var page = Self.startPage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let pageCount = 3

    /// 시작 장. DEBUG 에서 `-SSOnboardingPage <0~2>` 로 가운데 장부터 볼 수 있다(확인 · 스크린샷용).
    private static var startPage: Int {
        #if DEBUG
        return UserDefaults.standard.integer(forKey: "SSOnboardingPage")
        #else
        return 0
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("건너뛰기") { onFinish(false) }
                    .foregroundStyle(.secondary)
                    .padding()
            }

            Group {
                switch page {
                case 0: CaptureStep(trial: trial)
                case 1: StraightenStep(trial: trial)
                default: SearchStep(trial: trial)
                }
            }
            .id(page)
            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                              removal: .move(edge: .leading).combined(with: .opacity)))
            .frame(maxWidth: 520, maxHeight: .infinity)

            footer
        }
        .background(Color(.systemBackground))
        .task { await trial.prepare() }
    }

    private var footer: some View {
        VStack(spacing: 18) {
            HStack(spacing: 8) {
                ForEach(0..<pageCount, id: \.self) { index in
                    Capsule()
                        .fill(index == page ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: index == page ? 22 : 8, height: 8)
                }
            }
            .animation(.spring(duration: 0.4), value: page)
            .accessibilityHidden(true)

            Button(action: next) {
                Text(page == pageCount - 1 ? "시작하기" : "다음")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!trial.done.contains(page))
            .animation(.easeInOut, value: trial.done)
        }
        .frame(maxWidth: 520)
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
    }

    private func next() {
        if page == pageCount - 1 {
            onFinish(true)
        } else {
            withAnimation(.spring(duration: 0.5)) { page += 1 }
        }
    }
}

// MARK: - 해 본 것 — 강의실 사진과 앱이 그 사진에서 찾아낸 것

/// 강의실 장면 한 장을 앱의 진짜 처리(모서리 찾기 → 펴기 → 글자 읽기)에 통과시킨다.
@MainActor
private final class OnboardingTrial: ObservableObject {
    /// 읽어 낸 낱말 하나와, 펴진 장표 위 그 자리들(0~1, 왼쪽 위 원점).
    struct Word: Identifiable, Equatable {
        let text: String
        let boxes: [CGRect]
        var id: String { text }
    }

    /// 장면을 그리는 크기 — 뷰파인더와 같은 3:4.
    static let sceneSize = CGSize(width: 360, height: 480)

    @Published var photo: UIImage?
    @Published var quad: Quad?
    @Published var corrected: UIImage?
    @Published var words: [Word] = []
    /// 처리가 끝났는가(모서리를 못 찾았거나 글자가 없어도 끝난 것이다).
    @Published var processed = false
    /// 해 본 장 번호들.
    @Published var done: Set<Int> = []

    private var preparing: Task<Void, Never>?

    /// 장면을 찍어 처리해 둔다. 여러 곳에서 불러도 한 번만 한다.
    func prepare() async {
        if preparing == nil {
            preparing = Task { await process() }
        }
        await preparing?.value
    }

    private func process() async {
        let renderer = ImageRenderer(content: LectureScene().frame(width: Self.sceneSize.width, height: Self.sceneSize.height))
        renderer.scale = 3
        guard let image = renderer.uiImage else { processed = true; return }
        photo = image

        let result = await Task.detached(priority: .userInitiated) {
            let quad = ImageProcessor.detectSlideQuad(in: image)
            let corrected = quad.flatMap { ImageProcessor.perspectiveCorrected(image, quad: $0) } ?? image
            return (quad, corrected, Self.readWords(in: corrected))
        }.value
        quad = result.0
        corrected = result.1
        words = result.2
        processed = true
    }

    /// 낱말과 그 자리. 위에서부터(제목부터) 읽은 순서다.
    private nonisolated static func readWords(in image: UIImage) -> [Word] {
        guard let cgImage = image.downsampled(maxDimension: 2000).cgImage else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ImageProcessor.ocrLanguages
        try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])

        var order: [String] = []
        var boxes: [String: [CGRect]] = [:]
        let observations = (request.results ?? []).sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let line = candidate.string
            line.enumerateSubstrings(in: line.startIndex..., options: .byWords) { word, range, _, _ in
                guard let word, word.count >= 2, word.allSatisfy({ !$0.isNumber }), word.contains(where: \.isLetter),
                      let box = try? candidate.boundingBox(for: range)?.boundingBox else { return }
                let key = word.lowercased()
                if boxes[key] == nil { order.append(word) }
                // Vision 은 왼쪽 아래 원점이다 — 화면처럼 왼쪽 위 원점으로 뒤집는다.
                boxes[key, default: []].append(CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height))
            }
        }
        return order.map { Word(text: $0, boxes: boxes[$0.lowercased()] ?? []) }
    }
}

// MARK: - 한 장의 틀 — 큰 제목과 그림

private struct StepPage<Stage: View>: View {
    let title: LocalizedStringKey
    let done: Bool
    @ViewBuilder var stage: Stage

    var body: some View {
        VStack(spacing: 24) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                if done {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title)
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.45, bounce: 0.5), value: done)
            .padding(.horizontal, 24)

            stage
                .padding(.horizontal, 24)
                .frame(maxHeight: .infinity)
        }
        .padding(.top, 8)
        .padding(.bottom, 28)
    }
}

/// 사진을 틀 안에 맞춰 놓은 자리 — 사진 위에 모서리 · 낱말 자리를 그릴 때 쓴다.
private func fittedRect(_ size: CGSize, in bounds: CGSize) -> CGRect {
    guard size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: bounds) }
    let scale = min(bounds.width / size.width, bounds.height / size.height)
    let fitted = CGSize(width: size.width * scale, height: size.height * scale)
    return CGRect(x: (bounds.width - fitted.width) / 2, y: (bounds.height - fitted.height) / 2,
                  width: fitted.width, height: fitted.height)
}

// MARK: - 1. 찍기

private struct CaptureStep: View {
    @ObservedObject var trial: OnboardingTrial

    /// 뷰파인더에 뜬 감지 테두리. 처음엔 넉넉히 잡았다가 장표에 맞춰 조여 든다.
    @State private var liveQuad: Quad?
    @State private var locked = false
    @State private var captured = false
    @State private var flash = false
    @State private var sway = false
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        StepPage(title: "장표를 찍어 보세요", done: captured) {
            VStack(spacing: 22) {
                viewfinder
                shutter
            }
        }
        .onAppear {
            sway = true
            pulse = true
        }
        .task { await play() }
    }

    private var viewfinder: some View {
        ZStack {
            // 손에 든 카메라처럼 장면이 살짝 흔들린다
            ZStack {
                FittedScene()
                if let liveQuad {
                    DetectionOverlay(quad: liveQuad, aspect: 3 / 4, locked: locked)
                        .transition(.opacity)
                }
            }
            .scaleEffect(1.06)
            .offset(x: sway && !captured ? 5 : -5, y: sway && !captured ? -4 : 3)
            .rotationEffect(.degrees(sway && !captured ? 0.7 : -0.5))
            .animation(reduceMotion || captured ? .easeOut(duration: 0.2)
                                                : .easeInOut(duration: 2.4).repeatForever(autoreverses: true),
                       value: sway)

            // 찍힌 사진이 멈춰 선다
            if captured, let photo = trial.photo {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            }

            Color.white.opacity(flash ? 0.9 : 0).allowsHitTesting(false)
        }
        .aspectRatio(3 / 4, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .accessibilityElement()
        .accessibilityLabel(Text("강의실 화면에 장표가 떠 있어요"))
    }

    private var shutter: some View {
        Button(action: capture) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.85), lineWidth: 4).frame(width: 74, height: 74)
                Circle().fill(locked ? Color.green : Color.primary.opacity(0.85)).frame(width: 60, height: 60)
            }
            .scaleEffect(!captured && pulse && !reduceMotion ? 1.07 : 1)
            .animation(captured ? .default : .easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
            .animation(.easeInOut(duration: 0.3), value: locked)
        }
        .buttonStyle(ShutterPress())
        .accessibilityLabel(Text("셔터"))
        .disabled(captured)
        .opacity(captured ? 0.35 : 1)
    }

    /// 테두리가 장표를 찾아 조여 들고, 잠기고, 기다려도 안 누르면 저절로 찍힌다.
    private func play() async {
        await trial.prepare()
        guard let quad = trial.quad else { return }
        try? await Task.sleep(for: .milliseconds(700))
        withAnimation(.easeOut(duration: 0.3)) { liveQuad = quad.inflated(by: 0.08) }
        try? await Task.sleep(for: .milliseconds(450))
        liveQuad = quad   // 테두리는 스스로 부드럽게 따라간다 (DetectionOverlay)
        try? await Task.sleep(for: .milliseconds(900))
        guard !captured else { return }
        locked = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        // 장표가 잘 잡히면 앱도 저절로 찍는다 — 여기서도 그렇게.
        try? await Task.sleep(for: .seconds(2.5))
        if !Task.isCancelled && !captured { capture() }
    }

    private func capture() {
        guard !captured else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        flash = true
        withAnimation(.easeOut(duration: 0.45)) { flash = false }
        withAnimation(.easeInOut(duration: 0.25)) {
            captured = true
            liveQuad = nil
        }
        trial.done.insert(0)
    }
}

private extension Quad {
    /// 가운데에서 바깥으로 조금 부풀린 사각형 — 감지가 처음 넉넉히 잡는 모습.
    func inflated(by amount: CGFloat) -> Quad {
        let center = CGPoint(x: (topLeft.x + topRight.x + bottomRight.x + bottomLeft.x) / 4,
                             y: (topLeft.y + topRight.y + bottomRight.y + bottomLeft.y) / 4)
        func push(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x + (p.x - center.x) * amount * 2, y: p.y + (p.y - center.y) * amount * 2)
        }
        return Quad(topLeft: push(topLeft), topRight: push(topRight),
                    bottomRight: push(bottomRight), bottomLeft: push(bottomLeft))
    }
}

/// 누르면 살짝 눌리는 셔터.
private struct ShutterPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

// MARK: - 2. 펴기

private struct StraightenStep: View {
    @ObservedObject var trial: OnboardingTrial

    @State private var traced: CGFloat = 0
    @State private var straight = false

    var body: some View {
        StepPage(title: "반듯하게 펴 보세요", done: straight) {
            VStack(spacing: 22) {
                stage
                Button(action: straighten) {
                    Label("반듯하게 펴기", systemImage: "perspective")
                        .font(.headline)
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!trial.processed || straight)
                .opacity(straight ? 0 : 1)
            }
        }
        .onChange(of: trial.processed, initial: true) { _, processed in
            guard processed else { return }
            withAnimation(.easeInOut(duration: 1.1).delay(0.3)) { traced = 1 }
        }
    }

    private var stage: some View {
        GeometryReader { geo in
            if let photo = trial.photo {
                let photoRect = fittedRect(photo.size, in: geo.size)
                let quad = trial.quad ?? .full
                let points = corners(of: quad, in: photoRect)
                let result = trial.corrected.map { fittedRect($0.size, in: geo.size) } ?? photoRect

                ZStack(alignment: .topLeading) {
                    Image(uiImage: photo)
                        .resizable()
                        .frame(width: photoRect.width, height: photoRect.height)
                        .clipShape(RoundedRectangle(cornerRadius: 24))
                        .offset(x: photoRect.minX, y: photoRect.minY)
                        .opacity(straight ? 0 : 1)
                        .blur(radius: straight ? 8 : 0)

                    // 앱이 찾아낸 장표 테두리를 한 바퀴 그린다
                    QuadOutline(points: points)
                        .trim(from: 0, to: traced)
                        .stroke(Color.yellow, style: StrokeStyle(lineWidth: 3, lineJoin: .round))
                        .opacity(straight ? 0 : 1)
                    ForEach(points.indices, id: \.self) { index in
                        Circle()
                            .fill(Color.yellow)
                            .frame(width: 14, height: 14)
                            .scaleEffect(traced >= 1 && !straight ? 1 : 0.01)
                            .animation(.spring(duration: 0.4, bounce: 0.5), value: traced)
                            .position(points[index])
                    }

                    // 펴진 장표가 찾아낸 자리에서 틀 가득 펼쳐진다
                    if let corrected = trial.corrected {
                        let frame = straight ? result : bounds(of: points)
                        Image(uiImage: corrected)
                            .resizable()
                            .frame(width: frame.width, height: frame.height)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
                            .offset(x: frame.minX, y: frame.minY)
                            .opacity(straight ? 1 : 0)
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(straight ? Text("반듯하게 펴진 장표") : Text("비스듬하게 찍힌 장표"))
    }

    private func straighten() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(.spring(duration: 0.8, bounce: 0.2)) { straight = true }
        trial.done.insert(1)
    }

    private func corners(of quad: Quad, in rect: CGRect) -> [CGPoint] {
        [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft].map {
            CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height)
        }
    }

    private func bounds(of points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        let minX = xs.min() ?? 0, minY = ys.min() ?? 0
        return CGRect(x: minX, y: minY, width: (xs.max() ?? 0) - minX, height: (ys.max() ?? 0) - minY)
    }
}

/// 네 모서리를 잇는 테두리.
private struct QuadOutline: Shape {
    let points: [CGPoint]

    func path(in _: CGRect) -> Path {
        Path { path in
            path.addLines(points)
            path.closeSubpath()
        }
    }
}

// MARK: - 3. 찾기

private struct SearchStep: View {
    @ObservedObject var trial: OnboardingTrial

    @State private var typed = ""
    @State private var found: OnboardingTrial.Word?
    @State private var typing = false

    /// 고를 낱말 — 위에서부터 셋.
    private var choices: [OnboardingTrial.Word] { Array(trial.words.prefix(3)) }

    var body: some View {
        StepPage(title: "글자로 찾아 보세요", done: found != nil || (trial.processed && trial.words.isEmpty)) {
            VStack(spacing: 16) {
                searchField
                if !typing {
                    HStack(spacing: 8) {
                        ForEach(choices) { word in chip(word) }
                    }
                    .transition(.scale.combined(with: .opacity))
                }
                slide
            }
        }
        .onChange(of: trial.processed, initial: true) { _, processed in
            // 글자를 못 읽었으면 찾을 것이 없다 — 펴진 장표만 보여 주고 넘어가게 한다.
            if processed && trial.words.isEmpty { trial.done.insert(2) }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            if typed.isEmpty {
                Text("장표 텍스트·제목 검색").foregroundStyle(.tertiary)
            } else {
                Text(typed)
            }
            Spacer()
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    private func chip(_ word: OnboardingTrial.Word) -> some View {
        Button { search(word) } label: {
            Text(word.text)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.15), in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
    }

    private var slide: some View {
        GeometryReader { geo in
            if let image = trial.corrected {
                let rect = fittedRect(image.size, in: geo.size)
                ZStack(alignment: .topLeading) {
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: rect.width, height: rect.height)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .offset(x: rect.minX, y: rect.minY)

                    // 찾은 낱말 자리에 형광펜을 긋는다
                    if let found {
                        ForEach(found.boxes.indices, id: \.self) { index in
                            let box = found.boxes[index]
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.yellow.opacity(0.45))
                                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.orange, lineWidth: 2))
                                .frame(width: box.width * rect.width + 8, height: box.height * rect.height + 6)
                                .offset(x: rect.minX + box.minX * rect.width - 4,
                                        y: rect.minY + box.minY * rect.height - 3)
                                .transition(.scale(scale: 0.2, anchor: .leading).combined(with: .opacity))
                        }
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("반듯하게 펴진 장표"))
    }

    private func search(_ word: OnboardingTrial.Word) {
        guard !typing else { return }
        withAnimation { typing = true }
        Task { @MainActor in
            for character in word.text {
                typed.append(character)
                UISelectionFeedbackGenerator().selectionChanged()
                try? await Task.sleep(for: .milliseconds(110))
            }
            try? await Task.sleep(for: .milliseconds(150))
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(.spring(duration: 0.6, bounce: 0.35)) { found = word }
            trial.done.insert(2)
        }
    }
}

// MARK: - 강의실 — 모두가 같이 찍는 장면

/// 장면을 찍을 때와 같은 크기로 그린 뒤 틀에 맞춰 줄인다 — 그래야 찾아낸 모서리가 화면의 장표와 겹친다.
private struct FittedScene: View {
    var body: some View {
        GeometryReader { geo in
            let size = OnboardingTrial.sceneSize
            LectureScene()
                .frame(width: size.width, height: size.height)
                .scaleEffect(min(geo.size.width / size.width, geo.size.height / size.height))
                .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

/// 뒷줄에서 비스듬히 본 강의실 스크린. 실제 강의 · 회의에서 볼 법한 장표가 떠 있다.
private struct LectureScene: View {
    var body: some View {
        ZStack {
            // 어두운 강의실 벽과 천장 조명
            LinearGradient(colors: [Color(red: 0.16, green: 0.15, blue: 0.17), Color(red: 0.07, green: 0.07, blue: 0.08)],
                           startPoint: .top, endPoint: .bottom)
            HStack(spacing: 90) {
                ForEach(0..<3, id: \.self) { _ in
                    Capsule().fill(Color(white: 0.85).opacity(0.5)).frame(width: 46, height: 5)
                        .shadow(color: .white.opacity(0.6), radius: 8)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, 18)

            // 스크린 — 둘레 빛이 번진다
            screen
                .shadow(color: Color(white: 0.9).opacity(0.25), radius: 24)
                .rotation3DEffect(.degrees(26), axis: (x: 0.15, y: -1, z: 0.04), perspective: 0.55)
                .rotationEffect(.degrees(-3))
                .offset(x: 14, y: -34)
        }
        .overlay(alignment: .bottom) { audience }
        .clipped()
    }

    private var screen: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Text(verbatim: "2026")
                Text("매출 전망")
            }
            .font(.system(size: 21, weight: .heavy))
            .foregroundStyle(Color(red: 0.1, green: 0.15, blue: 0.3))

            VStack(alignment: .leading, spacing: 3) {
                // 숫자는 번역하지 않는다 — 말만 그 나라 말로.
                HStack(spacing: 4) { Text(verbatim: "•"); Text("국내 매출 성장"); Text(verbatim: "+18%") }
                HStack(spacing: 4) { Text(verbatim: "•"); Text("해외 비중"); Text(verbatim: "32% → 41%") }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color(white: 0.25))

            HStack(alignment: .bottom, spacing: 10) {
                ForEach(Array(zip(["23", "24", "25", "26"], [0.42, 0.58, 0.74, 1.0])), id: \.0) { year, height in
                    VStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(year == "26" ? Color(red: 0.95, green: 0.45, blue: 0.2) : Color(red: 0.22, green: 0.4, blue: 0.75))
                            .frame(width: 26, height: 52 * height)
                        Text(verbatim: "’\(year)").font(.system(size: 8, weight: .semibold)).foregroundStyle(.gray)
                    }
                }
                Spacer(minLength: 0)
                Text(verbatim: "12").font(.system(size: 8)).foregroundStyle(.gray)
            }
        }
        .padding(14)
        .frame(width: 250, height: 168, alignment: .topLeading)
        .background(Color(white: 0.97))
        .overlay(alignment: .top) {
            Rectangle().fill(Color(red: 0.22, green: 0.4, blue: 0.75)).frame(height: 4)
        }
    }

    /// 앞줄 사람들 — 머리와 어깨.
    private var audience: some View {
        HStack(alignment: .bottom, spacing: -6) {
            ForEach(0..<5, id: \.self) { index in
                VStack(spacing: -6) {
                    Circle().frame(width: 34, height: 34)
                    Capsule().frame(width: 76, height: 46)
                }
                .offset(y: index.isMultiple(of: 2) ? 14 : 6)
            }
        }
        .foregroundStyle(Color.black.opacity(0.85))
        .offset(y: 22)
    }
}

#Preview {
    OnboardingView { _ in }
}
#endif
