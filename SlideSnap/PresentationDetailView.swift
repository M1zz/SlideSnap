import SwiftUI

/// 슬라이드 상세 화면으로 이동하기 위한 라우트
struct SlideRoute: Hashable {
    let presentationID: UUID
    let slideID: UUID
}

/// 공유 시트에 넘길 파일 래퍼 (한 개)
struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// 공유 시트에 넘길 항목 묶음 (여러 개 — 이미지 여러 장 등)
struct ShareBundle: Identifiable {
    let id = UUID()
    let items: [Any]
}

/// UIActivityViewController 래퍼
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// 발표 하나의 장표 그리드 화면.
/// 선택 모드로 장표를 골라 이미지/PDF로 공유하거나 전체를 발표자료(PDF)로 내보낼 수 있습니다.
struct PresentationDetailView: View {

    @EnvironmentObject private var store: Store

    let presentationID: UUID

    @State private var showingCamera = false
    @State private var isExporting = false
    @State private var shareBundle: ShareBundle?

    // 선택 모드
    @State private var isSelecting = false
    @State private var selectedIDs: Set<UUID> = []

    private var presentation: Presentation? {
        store.presentation(presentationID)
    }

    var body: some View {
        Group {
            if let presentation {
                if presentation.slides.isEmpty {
                    ContentUnavailableView(
                        "장표가 없습니다",
                        systemImage: "camera.viewfinder",
                        description: Text("오른쪽 위 카메라 버튼을 눌러\n첫 장표를 촬영해 보세요.")
                    )
                } else {
                    grid(presentation)
                }
            } else {
                Color.clear
            }
        }
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraCaptureView(presentationID: presentationID)
        }
        .sheet(item: $shareBundle) { bundle in
            ShareSheet(items: bundle.items)
        }
        .navigationDestination(for: SlideRoute.self) { route in
            SlideDetailView(presentationID: route.presentationID, slideID: route.slideID)
        }
    }

    private var navTitle: String {
        if isSelecting {
            return selectedIDs.isEmpty ? "장표 선택" : "\(selectedIDs.count)장 선택"
        }
        return presentation?.title ?? ""
    }

    // MARK: - 툴바

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                Button("취소") { exitSelection() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(allSelected ? "선택 해제" : "모두") { toggleSelectAll() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                shareMenu(label: Image(systemName: "square.and.arrow.up"))
                    .disabled(selectedIDs.isEmpty || isExporting)
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingCamera = true
                } label: {
                    Image(systemName: "camera.fill")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        shareImages()
                    } label: {
                        Label("전체 이미지 공유", systemImage: "photo.on.rectangle")
                    }
                    Button {
                        exportPDF()
                    } label: {
                        Label("전체 PDF로 내보내기", systemImage: "doc.richtext")
                    }
                    Divider()
                    Button {
                        enterSelection()
                    } label: {
                        Label("선택", systemImage: "checkmark.circle")
                    }
                } label: {
                    if isExporting {
                        ProgressView()
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                .disabled(isExporting || (presentation?.slides.isEmpty ?? true))
            }
        }
    }

    /// 공유/내보내기 선택 메뉴 (선택 모드에서 사용)
    private func shareMenu(label: some View) -> some View {
        Menu {
            Button {
                shareImages()
            } label: {
                Label("이미지로 공유 (\(selectedIDs.count)장)", systemImage: "photo.on.rectangle")
            }
            Button {
                exportPDF()
            } label: {
                Label("PDF로 내보내기 (\(selectedIDs.count)장)", systemImage: "doc.richtext")
            }
        } label: {
            if isExporting { ProgressView() } else { label }
        }
    }

    // MARK: - 그리드

    private func grid(_ presentation: Presentation) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 10) {
                ForEach(Array(presentation.slides.enumerated()), id: \.element.id) { index, slide in
                    if isSelecting {
                        Button {
                            toggleSelect(slide.id)
                        } label: {
                            thumbnail(slide, number: index + 1)
                        }
                        .buttonStyle(.plain)
                    } else {
                        NavigationLink(value: SlideRoute(presentationID: presentationID, slideID: slide.id)) {
                            thumbnail(slide, number: index + 1)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding()
        }
    }

    private func thumbnail(_ slide: Slide, number: Int) -> some View {
        let selected = selectedIDs.contains(slide.id)
        return ZStack(alignment: .bottomTrailing) {
            Group {
                if let image = store.loadImage(slide.thumbFile) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle()
                        .fill(Color(.secondarySystemBackground))
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity)
            .frame(height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? Color.accentColor : Color(.separator), lineWidth: selected ? 2.5 : 0.5)
            )
            .opacity(isSelecting && !selected ? 0.6 : 1)

            Text("\(number)")
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.black.opacity(0.6), in: Capsule())
                .padding(5)

            if isSelecting {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : .white)
                    .background(Circle().fill(.black.opacity(0.35)))
                    .padding(5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    // MARK: - 선택

    private var allSelected: Bool {
        guard let presentation, !presentation.slides.isEmpty else { return false }
        return selectedIDs.count == presentation.slides.count
    }

    private func enterSelection() {
        selectedIDs = []
        isSelecting = true
    }

    private func exitSelection() {
        isSelecting = false
        selectedIDs = []
    }

    private func toggleSelect(_ id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func toggleSelectAll() {
        guard let presentation else { return }
        if allSelected {
            selectedIDs = []
        } else {
            selectedIDs = Set(presentation.slides.map { $0.id })
        }
    }

    // MARK: - 공유 / 내보내기

    /// 공유 대상 장표: 선택 모드면 선택된 것, 아니면 전체.
    private func targetSlides() -> [Slide] {
        guard let presentation else { return [] }
        if isSelecting && !selectedIDs.isEmpty {
            return presentation.slides.filter { selectedIDs.contains($0.id) }
        }
        return presentation.slides
    }

    private func shareImages() {
        let urls = targetSlides().map { store.imageURL($0.correctedFile) }
        guard !urls.isEmpty else { return }
        shareBundle = ShareBundle(items: urls)
    }

    private func exportPDF() {
        let slides = targetSlides()
        guard !slides.isEmpty, let presentation else { return }
        let title = presentation.title
        let urls = slides.map { store.imageURL($0.correctedFile) }
        isExporting = true

        Task {
            let pdfURL = await Task.detached(priority: .userInitiated) {
                PDFExporter.makePDF(title: title, imageURLs: urls)
            }.value

            isExporting = false
            if let pdfURL {
                shareBundle = ShareBundle(items: [pdfURL])
            }
        }
    }
}
