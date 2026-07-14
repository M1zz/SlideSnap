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
        .navigationTitle(pageTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showingAdjust = true
                    } label: {
                        Label("모서리 조정", systemImage: "crop.rotate")
                    }

                    Button {
                        if let slide = currentSlide {
                            shareItem = ShareItem(url: store.imageURL(slide.correctedFile))
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

    private var pageTitle: String {
        if let index = currentIndex {
            return "\(index + 1) / \(slides.count)"
        }
        return "장표"
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
            if let image = store.loadImage(showOriginal ? slide.originalFile : slide.correctedFile) {
                ZoomableImage(image: image)
                    .padding(.horizontal, 12)
            } else {
                ContentUnavailableView("이미지를 불러올 수 없습니다", systemImage: "photo")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
