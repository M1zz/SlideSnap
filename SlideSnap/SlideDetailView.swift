import SwiftUI

/// 한 발표의 장표들을 좌우로 넘겨 가며 보는 페이지 뷰어.
/// 탭한 장표에서 시작해 스와이프로 앞뒤 장표를 넘겨볼 수 있습니다.
/// 각 장표에서 보정본/원본 전환, 모서리 조정, 공유, 삭제가 가능합니다.
struct SlideDetailView: View {

    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss

    let presentationID: UUID
    let slideID: UUID

    @State private var currentSlideID: UUID
    @State private var showOriginal = false
    @State private var showingAdjust = false
    @State private var showingDeleteConfirm = false
    @State private var shareItem: ShareItem?
    @State private var isEnhancing = false

    @StateObject private var playback = AudioPlayback()
    /// 재생을 따라 장표를 넘기는 중인지(사용자가 넘긴 것과 구분해 되감기 반복을 막는다)
    @State private var autoAdvancing = false
    @State private var showTranscript = true
    @State private var transcriptHeight: CGFloat = 0

    init(presentationID: UUID, slideID: UUID) {
        self.presentationID = presentationID
        self.slideID = slideID
        self._currentSlideID = State(initialValue: slideID)
    }

    private var slides: [Slide] {
        store.presentation(presentationID)?.slides ?? []
    }

    private var currentIndex: Int? {
        slides.firstIndex { $0.id == currentSlideID }
    }

    private var currentSlide: Slide? {
        slides.first { $0.id == currentSlideID }
    }

    private var presentation: Presentation? {
        store.presentation(presentationID)
    }

    var body: some View {
        Group {
            if slides.isEmpty {
                Color.clear
            } else {
                VStack(spacing: 0) {
                    TabView(selection: $currentSlideID) {
                        ForEach(slides) { slide in
                            slideImage(slide)
                                .tag(slide.id)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))

                    audioPanel

                    filmstrip

                    Picker("보기", selection: $showOriginal) {
                        Text("보정본").tag(false)
                        Text("원본").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .padding()
                }
                .background(Color(.systemBackground))
            }
        }
        .overlay {
            if isEnhancing {
                ZStack {
                    Color.black.opacity(0.25).ignoresSafeArea()
                    ProgressView("가독성 보정 중…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
        .onChange(of: playback.currentTime) { _, time in
            followPlayback(time)
        }
        .onChange(of: currentSlideID) { _, _ in
            slideChangedDuringPlayback()
        }
        .onDisappear { playback.stop() }
        .navigationTitle(pageTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let slide = currentSlide {
                        Button {
                            toggleEnhance(slide)
                        } label: {
                            Label(slide.isEnhanced ? String(localized: "가독성 보정 끄기") : String(localized: "가독성 보정"),
                                  systemImage: slide.isEnhanced ? "wand.and.stars.inverse" : "wand.and.stars")
                        }
                    }

                    Button {
                        showingAdjust = true
                    } label: {
                        Label("모서리 조정", systemImage: "crop.rotate")
                    }

                    Button {
                        if let slide = currentSlide {
                            shareItem = ShareItem(url: store.imageURL(store.displayFile(for: slide)))
                        }
                    } label: {
                        Label("이미지 공유", systemImage: "square.and.arrow.up")
                    }

                    Button(role: .destructive) {
                        showingDeleteConfirm = true
                    } label: {
                        Label("삭제", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showingAdjust) {
            if let slide = currentSlide, let original = store.loadImage(slide.originalFile) {
                CornerAdjustView(image: original, initialQuad: slide.corners ?? .defaultInset) { newQuad in
                    Task {
                        await store.updateCorners(newQuad, slideID: slide.id, presentationID: presentationID)
                    }
                }
            }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .confirmationDialog("이 장표를 삭제할까요?", isPresented: $showingDeleteConfirm, titleVisibility: .visible) {
            Button("삭제", role: .destructive) {
                deleteCurrent()
            }
            Button("취소", role: .cancel) {}
        }
    }

    // MARK: - 녹음 듣기

    /// 이 장표를 찍던 순간부터 들을 수 있는 재생 막대와, 그때 받아쓴 말.
    @ViewBuilder
    private var audioPanel: some View {
        if let presentation, let slide = currentSlide,
           let (recording, range) = presentation.audioRange(for: slide) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    Button {
                        togglePlay(recording: recording, range: range)
                    } label: {
                        Image(systemName: isPlaying(recording) ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 34))
                    }
                    .accessibilityLabel(isPlaying(recording) ? Text("일시 정지") : Text("이 장표부터 듣기"))

                    Button {
                        playback.skip(by: -10)
                    } label: {
                        Image(systemName: "gobackward.10")
                    }
                    .disabled(playback.recordingID != recording.id)
                    .accessibilityLabel("10초 뒤로")

                    Button {
                        playback.skip(by: 10)
                    } label: {
                        Image(systemName: "goforward.10")
                    }
                    .disabled(playback.recordingID != recording.id)
                    .accessibilityLabel("10초 앞으로")

                    Spacer()

                    Text(playback.recordingID == recording.id
                         ? "\(playback.currentTime.clockText) / \(recording.duration.clockText)"
                         : "\(range.lowerBound.clockText) / \(recording.duration.clockText)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .font(.title3)

                if let spoken = presentation.transcriptText(for: slide) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showTranscript.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text("이 장표에서 한 말")
                                .font(.footnote.weight(.semibold))
                            Image(systemName: showTranscript ? "chevron.up" : "chevron.down")
                                .font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)

                    if showTranscript {
                        // 짧으면 그 높이만, 길면 110pt 안에서 스크롤한다.
                        ScrollView {
                            transcriptText(spoken)
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { transcriptHeight = $0 }
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(height: min(max(transcriptHeight, 20), 110))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground))
        }
    }

    private func transcriptText(_ spoken: String) -> some View {
        Text(spoken)
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    private func isPlaying(_ recording: Recording) -> Bool {
        playback.isPlaying && playback.recordingID == recording.id
    }

    private func togglePlay(recording: Recording, range: ClosedRange<TimeInterval>) {
        if isPlaying(recording) {
            playback.pause()
            return
        }
        // 멈춰 둔 곳이 이 장표 구간이면 거기서 이어 듣고, 아니면 이 장표를 찍던 순간부터 듣는다.
        if playback.recordingID == recording.id, range.contains(playback.currentTime) {
            playback.play()
        } else {
            playback.load(recording, url: store.audioURL(recording.file))
            playback.play(from: range.lowerBound)
        }
    }

    /// 재생 위치가 다음 장표 구간으로 넘어가면 화면도 그 장표로 넘긴다.
    private func followPlayback(_ time: TimeInterval) {
        guard playback.isPlaying, let presentation, let recordingID = playback.recordingID,
              let recording = presentation.allRecordings.first(where: { $0.id == recordingID }),
              let slideID = presentation.slideID(at: time, in: recording),
              slideID != currentSlideID else { return }
        autoAdvancing = true
        withAnimation(.easeInOut(duration: 0.25)) { currentSlideID = slideID }
    }

    /// 듣는 중에 사용자가 장표를 넘기면 그 장표를 찍던 순간으로 옮겨 듣는다.
    private func slideChangedDuringPlayback() {
        if autoAdvancing {
            autoAdvancing = false
            return
        }
        guard playback.isPlaying else { return }
        guard let presentation, let slide = currentSlide,
              let (recording, range) = presentation.audioRange(for: slide) else {
            playback.pause()
            return
        }
        playback.load(recording, url: store.audioURL(recording.file))
        playback.play(from: range.lowerBound)
    }

    private var pageTitle: String {
        if let index = currentIndex {
            return "\(index + 1) / \(slides.count)"
        }
        return String(localized: "장표")
    }

    /// 사진앱처럼 아래쪽에 작은 썸네일을 나열해 장표 사이를 빠르게 오갑니다.
    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(slides.enumerated()), id: \.element.id) { index, slide in
                        filmstripThumb(slide, number: index + 1)
                            .id(slide.id)
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    currentSlideID = slide.id
                                }
                            }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: currentSlideID) { _, newID in
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
            .onAppear {
                proxy.scrollTo(currentSlideID, anchor: .center)
            }
        }
        .frame(height: 64)
        .background(Color(.secondarySystemBackground))
    }

    private func filmstripThumb(_ slide: Slide, number: Int) -> some View {
        let selected = slide.id == currentSlideID
        return Group {
            if let image = store.loadImage(slide.thumbFile) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(Color(.tertiarySystemBackground))
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2.5)
        )
        .opacity(selected ? 1 : 0.6)
    }

    private func slideImage(_ slide: Slide) -> some View {
        Group {
            if let image = store.loadImage(showOriginal ? slide.originalFile : store.displayFile(for: slide)) {
                ZoomableImage(image: image)
                    .padding(.horizontal, 12)
            } else {
                ContentUnavailableView("이미지를 불러올 수 없습니다", systemImage: "photo")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 가독성 보정을 켜거나 끈다.
    private func toggleEnhance(_ slide: Slide) {
        isEnhancing = true
        Task {
            await store.setEnhanced(!slide.isEnhanced, slideID: slide.id, presentationID: presentationID)
            isEnhancing = false
        }
    }

    /// 현재 장표를 삭제하고, 남은 장표가 있으면 인접 장표로 이동한다.
    private func deleteCurrent() {
        guard let index = currentIndex else { return }
        store.deleteSlide(currentSlideID, from: presentationID)

        let remaining = slides
        guard !remaining.isEmpty else {
            dismiss()
            return
        }
        let newIndex = min(index, remaining.count - 1)
        currentSlideID = remaining[newIndex].id
    }
}

/// 핀치로 확대/축소하고, 확대 상태에서 드래그로 이동하며, 더블탭으로 확대·복귀하는 이미지.
/// 장표를 다시 볼 때 글씨를 자세히 보기 위한 뷰입니다.
private struct ZoomableImage: View {

    let image: UIImage

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        let magnify = MagnifyGesture()
            .onChanged { value in
                scale = min(max(lastScale * value.magnification, 1), 5)
            }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1.01 { resetPan() }
            }

        let pan = DragGesture()
            .onChanged { value in
                offset = CGSize(width: lastOffset.width + value.translation.width,
                                height: lastOffset.height + value.translation.height)
            }
            .onEnded { _ in lastOffset = offset }

        return Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .scaleEffect(scale)
            .offset(offset)
            .gesture(magnify)
            // 확대 중일 때만 드래그로 이동(축소 상태에선 페이지 넘김이 동작하도록 붙이지 않음).
            .applyIf(scale > 1.01) { $0.highPriorityGesture(pan) }
            .onTapGesture(count: 2) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if scale > 1.01 {
                        scale = 1; lastScale = 1; resetPan()
                    } else {
                        scale = 2.5; lastScale = 2.5
                    }
                }
            }
            .animation(.easeOut(duration: 0.15), value: scale)
    }

    private func resetPan() {
        offset = .zero
        lastOffset = .zero
    }
}

private extension View {
    /// 조건이 참일 때만 변형을 적용한다.
    @ViewBuilder
    func applyIf<T: View>(_ condition: Bool, _ transform: (Self) -> T) -> some View {
        if condition { transform(self) } else { self }
    }
}
