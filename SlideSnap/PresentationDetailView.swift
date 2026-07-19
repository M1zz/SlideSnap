import SwiftUI
import UniformTypeIdentifiers

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

    // 이름 변경
    @State private var showingRenameAlert = false
    @State private var renameText = ""

    // 선택 모드
    @State private var isSelecting = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var showingDeleteConfirm = false

    // 드래그 재배열
    @State private var draggingSlide: Slide?

    // 사진 가져오기
    @State private var showingPhotoImport = false
    @State private var importProgress: (done: Int, total: Int)?

    private var presentation: Presentation? {
        store.presentation(presentationID)
    }

    var body: some View {
        Group {
            if let presentation {
                if presentation.slides.isEmpty {
                    emptyState
                } else {
                    grid(presentation)
                }
            } else {
                Color.clear
            }
        }
        .overlay { importOverlay }
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraCaptureView(presentationID: presentationID)
        }
        .sheet(isPresented: $showingPhotoImport) {
            PhotoImportPicker { providers in
                importPhotos(providers)
            }
            .ignoresSafeArea()
        }
        .sheet(item: $shareBundle) { bundle in
            ShareSheet(items: bundle.items)
        }
        .navigationDestination(for: SlideRoute.self) { route in
            SlideDetailView(presentationID: route.presentationID, slideID: route.slideID)
        }
        .confirmationDialog(
            "선택한 \(selectedIDs.count)장을 삭제할까요?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("삭제", role: .destructive) { deleteSelected() }
            Button("취소", role: .cancel) {}
        }
        .alert("발표 제목 수정", isPresented: $showingRenameAlert) {
            TextField("발표 제목", text: $renameText)
            Button("저장") {
                store.renamePresentation(presentationID, to: renameText)
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("새 발표 제목을 입력하세요.")
        }
    }

    private func startRename() {
        renameText = presentation?.title ?? ""
        showingRenameAlert = true
    }

    // MARK: - 빈 화면 / 가져오기

    private var emptyState: some View {
        ContentUnavailableView {
            Label("장표가 없습니다", systemImage: "camera.viewfinder")
        } description: {
            Text("장표를 촬영하거나\n사진 앱에서 강의 사진을 가져올 수 있어요.")
        } actions: {
            Button {
                showingCamera = true
            } label: {
                Label("촬영하기", systemImage: "camera.fill")
            }
            .buttonStyle(.borderedProminent)
            Button {
                showingPhotoImport = true
            } label: {
                Label("사진에서 가져오기", systemImage: "photo.on.rectangle")
            }
        }
    }

    @ViewBuilder
    private var importOverlay: some View {
        if let importProgress {
            ZStack {
                Color.black.opacity(0.35).ignoresSafeArea()
                VStack(spacing: 14) {
                    ProgressView(value: Double(importProgress.done), total: Double(max(importProgress.total, 1)))
                        .progressViewStyle(.circular)
                    Text("사진 가져오는 중 \(importProgress.done)/\(importProgress.total)")
                        .font(.subheadline.weight(.semibold))
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
            .transition(.opacity)
        }
    }

    private func importPhotos(_ providers: [NSItemProvider]) {
        guard !providers.isEmpty else { return }
        Task {
            await store.importImages(providers, to: presentationID) { done, total in
                importProgress = (done, total)
            }
            importProgress = nil
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
            ToolbarItem(placement: .bottomBar) {
                Button(role: .destructive) {
                    showingDeleteConfirm = true
                } label: {
                    Label("삭제", systemImage: "trash")
                }
                .disabled(selectedIDs.isEmpty)
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
                        startRename()
                    } label: {
                        Label("이름 변경", systemImage: "pencil")
                    }
                    Button {
                        showingPhotoImport = true
                    } label: {
                        Label("사진에서 가져오기", systemImage: "photo.on.rectangle.angled")
                    }
                    if !(presentation?.slides.isEmpty ?? true) {
                        Divider()
                        Button {
                            shareImages()
                        } label: {
                            Label("전체 이미지 공유", systemImage: "photo.on.rectangle")
                        }
                        pdfMenu(titleSuffix: "")
                        Divider()
                        Button {
                            enterSelection()
                        } label: {
                            Label("선택", systemImage: "checkmark.circle")
                        }
                    }
                } label: {
                    if isExporting {
                        ProgressView()
                    } else {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                .disabled(isExporting)
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
            pdfMenu(titleSuffix: " (\(selectedIDs.count)장)")
        } label: {
            if isExporting { ProgressView() } else { label }
        }
    }

    /// PDF 레이아웃(한 장/두 장/네 장)을 고르는 하위 메뉴.
    private func pdfMenu(titleSuffix: String) -> some View {
        Menu {
            ForEach([PDFLayout.one, .two, .four]) { layout in
                Button {
                    exportPDF(layout: layout)
                } label: {
                    Text(layout.label)
                }
            }
        } label: {
            Label("PDF로 내보내기" + titleSuffix, systemImage: "doc.richtext")
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
                        .opacity(draggingSlide?.id == slide.id ? 0.3 : 1)
                        .onDrag {
                            draggingSlide = slide
                            return NSItemProvider(object: slide.id.uuidString as NSString)
                        }
                        .onDrop(
                            of: [.text],
                            delegate: SlideReorderDropDelegate(
                                item: slide,
                                dragging: $draggingSlide,
                                presentationID: presentationID,
                                store: store
                            )
                        )
                        .contextMenu {
                            NavigationLink(value: SlideRoute(presentationID: presentationID, slideID: slide.id)) {
                                Label("열기", systemImage: "arrow.up.left.and.arrow.down.right")
                            }
                            Button {
                                shareBundle = ShareBundle(items: [store.imageURL(store.displayFile(for: slide))])
                            } label: {
                                Label("이미지 공유", systemImage: "square.and.arrow.up")
                            }
                            Button(role: .destructive) {
                                store.deleteSlide(slide.id, from: presentationID)
                            } label: {
                                Label("삭제", systemImage: "trash")
                            }
                        }
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

    private func deleteSelected() {
        store.deleteSlides(selectedIDs, from: presentationID)
        exitSelection()
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
        let urls = targetSlides().map { store.imageURL(store.displayFile(for: $0)) }
        guard !urls.isEmpty else { return }
        shareBundle = ShareBundle(items: urls)
    }

    private func exportPDF(layout: PDFLayout = .one) {
        let slides = targetSlides()
        guard !slides.isEmpty, let presentation else { return }
        let title = presentation.title
        let urls = slides.map { store.imageURL(store.displayFile(for: $0)) }
        isExporting = true

        Task {
            let pdfURL = await Task.detached(priority: .userInitiated) {
                PDFExporter.makePDF(title: title, imageURLs: urls, layout: layout)
            }.value

            isExporting = false
            if let pdfURL {
                shareBundle = ShareBundle(items: [pdfURL])
            }
        }
    }
}

/// 그리드에서 장표를 길게 눌러 드래그하면 순서를 바꿉니다.
/// 드래그 중인 장표가 다른 장표 위로 들어오면 그 자리로 실시간 이동합니다.
private struct SlideReorderDropDelegate: DropDelegate {
    let item: Slide
    @Binding var dragging: Slide?
    let presentationID: UUID
    let store: Store

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging.id != item.id else { return }
        MainActor.assumeIsolated {
            store.moveSlide(dragging.id, before: item.id, in: presentationID)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
