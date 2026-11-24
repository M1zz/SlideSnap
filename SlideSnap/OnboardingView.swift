//
//  OnboardingView.swift
//  SlideSnap
//
//  처음 쓰는 사람이 진짜로 해 본다 — 찍기 · 펴기 · 찾기.
//  카메라도, 모서리 찾기 · 반듯하게 펴기 · 글자 읽기도 앱이 실제로 쓰는 그것이다. 가짜 그림이 아니다.
//  글은 큰 제목 한 줄뿐, 나머지는 그림과 움직임이 말한다. 한 장을 해 봐야 다음 단추가 깨어난다(건너뛰기는 늘 있다).
//  눈앞에 장표가 없으면 셔터 옆에서 앨범의 강의 사진을 고르거나, 강의실 그림(예시)을 찍는다.
//  카메라가 없거나(시뮬레이터) 허락을 받지 못해도 강의실 그림을 찍는다 — 그 뒤의 펴기 · 찾기는 그래도 진짜다.
//  가로로 들고 찍은 사진도 가로 그대로 다룬다(아이폰 화면은 세로로 서 있어도 사진은 돌아 나온다).
//  발표가 하나도 없는 첫 실행에만 뜬다 (→ PresentationListView.reacting).
//

#if os(iOS) && !targetEnvironment(macCatalyst)
import SwiftUI
import AVFoundation
import PhotosUI
import Vision

struct OnboardingView: View {
    enum Outcome {
        /// 건너뛰었다
        case skipped
        /// 강의실 그림으로 해 봤다 — 남길 장표는 없다
        case triedSample
        /// 카메라로 진짜 찍었다 — 첫 발표로 남긴다
        case captured(UIImage)
    }

    var onFinish: (Outcome) -> Void

    @StateObject private var trial = OnboardingTrial()
    @State private var page = Self.startPage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let pageCount = 3

    /// 시작 장. DEBUG 에서 `-SSOnboardingPage <0~2>` 로 가운데 장부터 볼 수 있다(그 장은 강의실 그림으로 채운다).
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
                Button("건너뛰기") { onFinish(.skipped) }
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
        .task {
            if page > 0 { await trial.useSample() }
        }
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
        guard page == pageCount - 1 else {
            withAnimation(.spring(duration: 0.5)) { page += 1 }
            return
        }
        if let photo = trial.photo, !trial.isSample {
            onFinish(.captured(photo))
        } else {
            onFinish(.triedSample)
        }
    }
}

// MARK: - 해 본 것 — 찍은 사진과 앱이 그 사진에서 찾아낸 것

/// 찍은 사진 한 장을 앱의 진짜 처리(모서리 찾기 → 펴기 → 글자 읽기)에 통과시킨다.
@MainActor
private final class OnboardingTrial: ObservableObject {
    /// 읽어 낸 낱말 하나와, 펴진 장표 위 그 자리들(0~1, 왼쪽 위 원점).
    struct Word: Identifiable, Equatable {
        let text: String
        let boxes: [CGRect]
        var id: String { text }
    }

    @Published var photo: UIImage?
    @Published var isSample = false
    @Published var quad: Quad?
    @Published var corrected: UIImage?
    @Published var words: [Word] = []
    /// 처리가 끝났는가(모서리를 못 찾았거나 글자가 없어도 끝난 것이다).
    @Published var processed = false
    /// 해 본 장 번호들.
    @Published var done: Set<Int> = []

    func take(_ image: UIImage, sample: Bool) async {
        let normalized = image.orientationNormalized()
        photo = normalized
        isSample = sample
        quad = nil
        corrected = nil
        words = []
        processed = false
        done = [0]

        let result = await Task.detached(priority: .userInitiated) {
            let quad = ImageProcessor.detectSlideQuad(in: normalized)
            let corrected = quad.flatMap { ImageProcessor.perspectiveCorrected(normalized, quad: $0) } ?? normalized
            return (quad, corrected, Self.readWords(in: corrected))
        }.value
        guard photo === normalized else { return }   // 그 사이 다시 찍었다
        quad = result.0
        corrected = result.1
        words = result.2
        processed = true
    }

    /// 다시 찍으려고 비운다.
    func reset() {
        photo = nil
        quad = nil
        corrected = nil
        words = []
        processed = false
        done = []
    }

    /// 강의실 그림을 찍은 것으로 한다 — 카메라가 없거나, 가운데 장부터 볼 때.
    func useSample() async {
        let renderer = ImageRenderer(content: SampleScene().frame(width: 360, height: 480))
        renderer.scale = 3
        guard let image = renderer.uiImage else { return }
        await take(image, sample: true)
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
                guard let word, word.count >= 2, word.contains(where: \.isLetter),
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

    @StateObject private var camera = CameraController()
    @State private var flash = false
    @State private var pulse = false
    /// 눈앞에 장표가 없어 강의실 그림(예시)을 보고 있는가.
    @State private var showingSample = false
    @State private var albumItem: PhotosPickerItem?
    /// 한참 못 찍고 있으면 '앨범 · 예시' 단추가 살짝 튄다.
    @State private var nudge = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 진짜 카메라를 쓸 수 있는가. 없거나(시뮬레이터) 허락을 못 받았으면 강의실 그림을 찍는다.
    private var hasCamera: Bool {
        !camera.authorizationDenied
            && AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
    }
    /// 지금 뷰파인더에 카메라가 비치는가.
    private var cameraLive: Bool { hasCamera && !showingSample }

    var body: some View {
        StepPage(title: "장표를 찍어 보세요", done: trial.photo != nil) {
            VStack(spacing: 22) {
                viewfinder
                HStack {
                    album.frame(maxWidth: .infinity)
                    shutter
                    sample.frame(maxWidth: .infinity)
                }
            }
        }
        .onAppear {
            pulse = true
            if hasCamera { camera.start() }
        }
        .onDisappear { camera.stop() }
        .onChange(of: albumItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    await trial.take(image, sample: false)
                }
                albumItem = nil
            }
        }
        .task {
            // 5초 넘게 못 찍고 있으면 — 눈앞에 장표가 없는 것이다 — 옆 단추를 살짝 튀게 한다.
            try? await Task.sleep(for: .seconds(5))
            if trial.photo == nil { nudge += 1 }
        }
    }

    /// 앨범에서 고르기 — 찍어 둔 강의 사진으로 진짜 해 본다.
    private var album: some View {
        PhotosPicker(selection: $albumItem, matching: .images) {
            sideIcon("photo.on.rectangle.angled")
        }
        .accessibilityLabel(Text("사진에서 가져오기"))
        .disabled(trial.photo != nil)
        .opacity(trial.photo != nil ? 0 : 1)
    }

    /// 예시 장표 — 강의실 그림을 뷰파인더에 띄운다. 카메라가 없으면 늘 그림이라 단추가 없다.
    @ViewBuilder
    private var sample: some View {
        if hasCamera {
            Button {
                withAnimation(.easeInOut(duration: 0.3)) { showingSample.toggle() }
            } label: {
                sideIcon(showingSample ? "camera.fill" : "rectangle.inset.filled.and.person.filled")
            }
            .accessibilityLabel(showingSample ? Text("카메라") : Text("예시 장표"))
            .disabled(trial.photo != nil)
            .opacity(trial.photo != nil ? 0 : 1)
        } else {
            Color.clear.frame(width: 54, height: 54)   // 셔터를 가운데에 두려고 자리만 잡는다
        }
    }

    private func sideIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.title2)
            .foregroundStyle(Color.primary)
            .frame(width: 54, height: 54)
            .background(Color(.secondarySystemBackground), in: Circle())
            .symbolEffect(.bounce, value: nudge)
            .contentTransition(.symbolEffect(.replace))
    }

    private var viewfinder: some View {
        ZStack {
            if hasCamera {
                Color.black
                CameraPreview(camera: camera)
                    .opacity(showingSample ? 0 : 1)
                if let quad = camera.detectedQuad {
                    DetectionOverlay(quad: quad, aspect: camera.sourceAspect, locked: camera.isLocked)
                        .allowsHitTesting(false)
                }
            }
            if !cameraLive {
                SampleScene().transition(.opacity)
            }

            // 찍은 사진이 멈춰 선다. 가로로 찍었으면 가로 그대로 — 잘라 내지 않고 틀 안에 맞춘다.
            if let photo = trial.photo {
                Color.black
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFit()
                    .transition(.opacity)
            }

            Color.white.opacity(flash ? 0.9 : 0).allowsHitTesting(false)
        }
        .aspectRatio(3 / 4, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(alignment: .topTrailing) {
            if trial.photo != nil { retake }
        }
    }

    private var retake: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) { trial.reset() }
        } label: {
            Image(systemName: "arrow.counterclockwise")
                .font(.headline)
                .foregroundStyle(.white)
                .padding(10)
                .background(.black.opacity(0.5), in: Circle())
        }
        .padding(12)
        .accessibilityLabel(Text("다시 찍기"))
    }

    private var shutter: some View {
        Button(action: capture) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.85), lineWidth: 4).frame(width: 74, height: 74)
                Circle().fill(Color.primary.opacity(0.85)).frame(width: 60, height: 60)
            }
            .scaleEffect(trial.photo == nil && pulse && !reduceMotion ? 1.07 : 1)
            .animation(trial.photo == nil ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default,
                       value: pulse)
        }
        .buttonStyle(ShutterPress())
        .accessibilityLabel(Text("셔터"))
        .disabled(trial.photo != nil)
        .opacity(trial.photo != nil ? 0.35 : 1)
    }

    private func capture() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        flash = true
        withAnimation(.easeOut(duration: 0.4)) { flash = false }
        if cameraLive {
            camera.capturePhoto { image in
                Task { @MainActor in await trial.take(image, sample: false) }
            }
        } else {
            Task { await trial.useSample() }
        }
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
            // 글자가 없는 사진이면 찾을 것이 없다 — 펴진 장표만 보여 주고 넘어가게 한다.
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

// MARK: - 강의실 그림 — 카메라가 없을 때 찍는 장면

/// 비스듬히 보이는 발표 화면. 이 그림을 찍어도 모서리 찾기 · 펴기 · 글자 읽기는 진짜로 돈다.
private struct SampleScene: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.24), Color(white: 0.1)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 10) {
                Text("매출 전망")
                    .font(.system(size: 26, weight: .heavy))
                Text("고객 인터뷰")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.gray)
                HStack(alignment: .bottom, spacing: 12) {
                    ForEach([0.35, 0.55, 0.7, 1.0], id: \.self) { height in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(height == 1 ? Color.blue : Color.blue.opacity(0.4))
                            .frame(width: 34, height: 70 * height)
                    }
                }
            }
            .foregroundStyle(.black)
            .padding(18)
            .frame(width: 250, height: 170, alignment: .topLeading)
            .background(.white, in: Rectangle())
            .rotation3DEffect(.degrees(24), axis: (x: 0.2, y: -1, z: 0.05), perspective: 0.6)
            .rotationEffect(.degrees(-4))
            .offset(y: -30)
        }
        .overlay(alignment: .bottom) {
            HStack(spacing: 14) {
                ForEach(0..<6, id: \.self) { _ in
                    Circle().fill(Color.black.opacity(0.6)).frame(width: 44, height: 44)
                }
            }
            .offset(y: 16)
        }
        .clipped()
    }
}

#Preview {
    OnboardingView { _ in }
}
#endif
