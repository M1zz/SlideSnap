//
//  OnboardingView.swift
//  SlideSnap
//
//  처음 쓰는 사람에게 세 가지를 손으로 해 보게 한다 — 찍기 · 펴기 · 찾기.
//  읽는 안내가 아니라 누르는 안내다. 한 장을 해 봐야 다음 단추가 깨어난다(건너뛰기는 늘 있다).
//  발표가 하나도 없는 첫 실행에만 뜬다 (→ PresentationListView.reacting).
//  찍는 기기(iPhone · iPad)에서만 — Mac · Vision Pro 는 찍지 않으니 보여 줄 것이 다르다.
//

#if os(iOS) && !targetEnvironment(macCatalyst)
import SwiftUI

struct OnboardingView: View {
    /// 끝났을 때. 마지막 단추로 끝냈으면 true — 바로 카메라를 연다.
    var onFinish: (_ wantsCamera: Bool) -> Void

    @State private var page = Self.startPage
    @State private var tried: Set<Int> = []
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
                case 0: CaptureDemo(done: markTried)
                case 1: StraightenDemo(done: markTried)
                default: SearchDemo(done: markTried)
                }
            }
            .id(page)
            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                              removal: .move(edge: .leading).combined(with: .opacity)))
            .frame(maxWidth: 520, maxHeight: .infinity)

            footer
        }
        .background(Color(.systemBackground))
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
                Text(isLast ? "첫 장표 찍으러 가기" : "다음")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!tried.contains(page))
            .animation(.easeInOut, value: tried)
        }
        .frame(maxWidth: 520)
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
    }

    private var isLast: Bool { page == pageCount - 1 }

    private func markTried() {
        tried.insert(page)
    }

    private func next() {
        if isLast {
            onFinish(true)
        } else {
            withAnimation(.spring(duration: 0.5)) { page += 1 }
        }
    }
}

// MARK: - 한 장의 머리 · 그림 · 알림 말

/// 제목 · 설명 · 그림 · 아래 말(해 보기 전엔 할 일, 해 본 뒤엔 칭찬).
private struct DemoPage<Stage: View>: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let hint: LocalizedStringKey
    let praise: LocalizedStringKey
    let done: Bool
    @ViewBuilder var stage: Stage

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text(title)
                    .font(.title.bold())
                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)

            stage
                .padding(.horizontal, 24)
                .frame(maxHeight: .infinity)

            Label(done ? praise : hint, systemImage: done ? "checkmark.circle.fill" : "hand.tap.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(done ? Color.green : Color.accentColor)
                .contentTransition(.opacity)
                .animation(.easeInOut, value: done)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
        }
    }
}

// MARK: - 장표 그림

/// 그려 낸 장표 한 장 — 제목 줄과 막대 그래프. `variant` 로 그래프 모양이 바뀐다.
private struct SlideArt: View {
    var variant = 0
    var title: LocalizedStringKey?

    private static let bars: [[CGFloat]] = [[0.35, 0.55, 0.45, 0.8], [0.7, 0.4, 0.6, 0.3], [0.25, 0.45, 0.65, 0.9], [0.5, 0.75, 0.4, 0.6]]

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(.white)
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 8) {
                    if let title {
                        Text(title)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.black)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    } else {
                        Capsule().fill(Color.black.opacity(0.75)).frame(width: 70, height: 7)
                        Capsule().fill(Color.black.opacity(0.25)).frame(width: 46, height: 5)
                    }
                    GeometryReader { geo in
                        HStack(alignment: .bottom, spacing: geo.size.width * 0.08) {
                            ForEach(Array(Self.bars[variant % Self.bars.count].enumerated()), id: \.offset) { index, height in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(index == 3 ? Color.accentColor : Color.accentColor.opacity(0.4))
                                    .frame(height: geo.size.height * height)
                            }
                        }
                        .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
                .padding(10)
            }
            .aspectRatio(16 / 9, contentMode: .fit)
    }
}

/// 강의실 벽 — 장표 뒤에 깔리는 어두운 배경.
private struct RoomBackdrop: View {
    var body: some View {
        LinearGradient(colors: [Color(white: 0.22), Color(white: 0.1)], startPoint: .top, endPoint: .bottom)
            .overlay(alignment: .bottom) {
                // 앞줄 사람들의 머리
                HStack(spacing: 14) {
                    ForEach(0..<6, id: \.self) { _ in
                        Circle().fill(Color.black.opacity(0.55)).frame(width: 34, height: 34)
                    }
                }
                .offset(y: 14)
            }
    }
}

// MARK: - 1. 찍기

private struct CaptureDemo: View {
    var done: () -> Void

    @State private var shots = 0
    @State private var flash = false
    @State private var flying = false
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        DemoPage(title: "찰칵, 장표를 담아요",
                 message: "장표가 바뀔 때마다 셔터만 누르면 돼요.",
                 hint: "셔터를 눌러 보세요",
                 praise: "잘했어요! 찍은 장표는 발표별로 모여요.",
                 done: shots > 0) {
            VStack(spacing: 18) {
                viewfinder
                shutter
            }
        }
        .onAppear { pulse = true }
    }

    private var viewfinder: some View {
        ZStack {
            RoomBackdrop()
            SlideArt(variant: shots)
                .frame(width: 210)
                .rotation3DEffect(.degrees(14), axis: (x: 0.1, y: -1, z: 0), perspective: 0.6)
                .overlay {
                    // 장표를 찾았다는 노란 모서리
                    CornerBrackets()
                        .stroke(Color.yellow, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 230, height: 140)
                        .scaleEffect(pulse && !reduceMotion ? 1.04 : 0.98)
                        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
                }
                .id(shots)
                .transition(.opacity)

            // 찍은 장이 썸네일로 날아간다
            if flying {
                SlideArt(variant: shots)
                    .frame(width: 210)
                    .transition(.asymmetric(insertion: .identity,
                                            removal: .scale(scale: 0.2, anchor: .bottomLeading)
                                                .combined(with: .offset(x: -70, y: 70))
                                                .combined(with: .opacity)))
            }

            Color.white.opacity(flash ? 0.9 : 0).allowsHitTesting(false)
        }
        .overlay(alignment: .bottomLeading) { thumbnail }
        .aspectRatio(4 / 3, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .accessibilityElement()
        .accessibilityLabel(Text("강의실 화면에 장표가 떠 있어요"))
    }

    @ViewBuilder
    private var thumbnail: some View {
        if shots > 0 {
            SlideArt(variant: shots - 1)
                .frame(width: 54)
                .overlay(alignment: .topTrailing) {
                    Text("\(shots)")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(Color.accentColor, in: Circle())
                        .offset(x: 8, y: -8)
                        .contentTransition(.numericText())
                }
                .padding(12)
                .transition(.scale.combined(with: .opacity))
        }
    }

    private var shutter: some View {
        Button(action: capture) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.85), lineWidth: 4).frame(width: 74, height: 74)
                Circle().fill(Color.primary.opacity(0.85)).frame(width: 60, height: 60)
            }
            .scaleEffect(shots == 0 && pulse && !reduceMotion ? 1.06 : 1)
            .animation(shots == 0 ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: pulse)
        }
        .buttonStyle(ShutterPress())
        .accessibilityLabel(Text("셔터"))
    }

    private func capture() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        flying = true
        flash = true
        withAnimation(.easeOut(duration: 0.35)) { flash = false }
        withAnimation(.spring(duration: 0.55)) {
            flying = false
            shots += 1
        }
        done()
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

/// 네 귀퉁이만 그린 사각형 — 카메라가 장표를 잡았다는 표시.
private struct CornerBrackets: Shape {
    func path(in rect: CGRect) -> Path {
        let arm = min(rect.width, rect.height) * 0.18
        var path = Path()
        for (corner, dx, dy) in [(CGPoint(x: rect.minX, y: rect.minY), 1.0, 1.0),
                                 (CGPoint(x: rect.maxX, y: rect.minY), -1.0, 1.0),
                                 (CGPoint(x: rect.minX, y: rect.maxY), 1.0, -1.0),
                                 (CGPoint(x: rect.maxX, y: rect.maxY), -1.0, -1.0)] {
            path.move(to: CGPoint(x: corner.x + arm * dx, y: corner.y))
            path.addLine(to: corner)
            path.addLine(to: CGPoint(x: corner.x, y: corner.y + arm * dy))
        }
        return path
    }
}

// MARK: - 2. 펴기

private struct StraightenDemo: View {
    var done: () -> Void

    @State private var traced: CGFloat = 0
    @State private var straight = false

    var body: some View {
        DemoPage(title: "비스듬해도 반듯하게",
                 message: "뒷자리에서 찍어도 장표만 찾아 반듯하게 펴 줘요.",
                 hint: "아래 단추를 눌러 보세요",
                 praise: "펴졌어요! 원본도 그대로 남아 있어요.",
                 done: straight) {
            VStack(spacing: 18) {
                photo
                Button {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    withAnimation(.spring(duration: 0.8, bounce: 0.25)) { straight = true }
                    done()
                } label: {
                    Label("반듯하게 펴기", systemImage: "perspective")
                        .font(.headline)
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(straight)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).delay(0.3)) { traced = 1 }
        }
    }

    private var photo: some View {
        ZStack {
            RoomBackdrop().opacity(straight ? 0 : 1)
            SlideArt(variant: 2)
                .overlay {
                    // 찾아낸 테두리를 한 바퀴 그린다
                    Rectangle()
                        .trim(from: 0, to: traced)
                        .stroke(Color.yellow, lineWidth: 3)
                        .opacity(straight ? 0 : 1)
                }
                .overlay { cornerDots.opacity(straight ? 0 : (traced >= 1 ? 1 : 0)) }
                .frame(width: straight ? nil : 200)
                .rotation3DEffect(.degrees(straight ? 0 : 32), axis: (x: 0.25, y: -1, z: 0.05), perspective: 0.7)
                .rotationEffect(.degrees(straight ? 0 : -5))
                .offset(x: straight ? 0 : 18, y: straight ? 0 : -14)
                .shadow(color: .black.opacity(straight ? 0.15 : 0), radius: 10, y: 4)
                .padding(straight ? 4 : 0)
        }
        .aspectRatio(4 / 3, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .accessibilityElement()
        .accessibilityLabel(straight ? Text("반듯하게 펴진 장표") : Text("비스듬하게 찍힌 장표"))
    }

    private var cornerDots: some View {
        GeometryReader { geo in
            ForEach(0..<4, id: \.self) { index in
                Circle()
                    .fill(Color.yellow)
                    .frame(width: 12, height: 12)
                    .position(x: index % 2 == 0 ? 0 : geo.size.width,
                              y: index < 2 ? 0 : geo.size.height)
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.5), value: traced)
    }
}

// MARK: - 3. 찾기

private struct SearchDemo: View {
    var done: () -> Void

    @State private var typed = ""
    @State private var found = false
    @State private var typing = false

    /// 찾는 장표는 늘 셋째 장(매출 전망)이다. 낱말을 번역해도 맞는 장이 어긋나지 않게 자리로 정한다.
    private let matchIndex = 2
    private let titles: [LocalizedStringKey] = ["시장 규모", "고객 인터뷰", "매출 전망", "다음 단계"]
    private var keyword: String { String(localized: "매출", comment: "Onboarding search keyword — must appear in the title '매출 전망'") }

    var body: some View {
        DemoPage(title: "글자로 바로 찾기",
                 message: "장표 속 글자를 읽어 두어서 낱말 하나로 찾아요.",
                 hint: "낱말을 눌러 보세요",
                 praise: "찾았어요! 지난 강의도 금방 꺼내 봐요.",
                 done: found) {
            VStack(spacing: 14) {
                searchField
                if typed.isEmpty && !typing { chip }
                grid
            }
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

    private var chip: some View {
        Button(action: search) {
            Label(keyword, systemImage: "text.magnifyingglass")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.15), in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .transition(.scale.combined(with: .opacity))
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(titles.indices, id: \.self) { index in
                let hit = index == matchIndex
                SlideArt(variant: index, title: titles[index])
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(found && hit ? Color.accentColor : Color.secondary.opacity(0.25),
                                    lineWidth: found && hit ? 3 : 1)
                    }
                    .overlay(alignment: .topTrailing) {
                        if found && hit {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.white, Color.accentColor)
                                .offset(x: 8, y: -8)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .opacity(found && !hit ? 0.25 : 1)
                    .scaleEffect(found ? (hit ? 1.06 : 0.94) : 1)
                    .zIndex(hit ? 1 : 0)
            }
        }
    }

    private func search() {
        guard !typing else { return }
        withAnimation { typing = true }
        Task { @MainActor in
            for character in keyword {
                typed.append(character)
                UISelectionFeedbackGenerator().selectionChanged()
                try? await Task.sleep(for: .milliseconds(110))
            }
            try? await Task.sleep(for: .milliseconds(150))
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(.spring(duration: 0.6, bounce: 0.3)) { found = true }
            done()
        }
    }
}

#Preview {
    OnboardingView { _ in }
}
#endif
