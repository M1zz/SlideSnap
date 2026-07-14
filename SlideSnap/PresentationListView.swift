import SwiftUI

/// 첫 화면 — 발표 목록
struct PresentationListView: View {

    @EnvironmentObject private var store: Store

    @State private var showingNewAlert = false
    @State private var newTitle = ""

    @State private var renamingID: UUID?
    @State private var renameText = ""

    @State private var showingPhotoImport = false
    @State private var importProgress: (done: Int, total: Int)?

    @State private var searchText = ""

    @State private var path = NavigationPath()
    @State private var showingCamera = false
    @State private var cameraPresentationID: UUID?
    @State private var hasAutoLaunchedCamera = false
    @State private var cameraCaptured = false
    @State private var cameraCreatedNew = false

    /// 이 시간 이내에 촬영이 이어지면 같은 발표로 묶는다.
    private static let groupingWindow: TimeInterval = 5 * 60

    var body: some View {
        NavigationStack(path: $path) {
            content
            .navigationTitle("장표스냅")
            .searchable(text: $searchText, prompt: "장표 텍스트·제목 검색")
            .navigationDestination(for: UUID.self) { id in
                PresentationDetailView(presentationID: id)
            }
            .navigationDestination(for: SlideRoute.self) { route in
                SlideDetailView(presentationID: route.presentationID, slideID: route.slideID)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        openCamera()
                    } label: {
                        Image(systemName: "camera.fill")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            newTitle = Store.defaultTitle()
                            showingNewAlert = true
                        } label: {
                            Label("빈 발표 만들기", systemImage: "rectangle.badge.plus")
                        }
                        Button {
                            showingPhotoImport = true
                        } label: {
                            Label("사진에서 가져오기", systemImage: "photo.on.rectangle.angled")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .fullScreenCover(isPresented: $showingCamera, onDismiss: cameraFinished) {
                if let cameraPresentationID {
                    CameraCaptureView(presentationID: cameraPresentationID) {
                        cameraCaptured = true
                    }
                }
            }
            .sheet(isPresented: $showingPhotoImport) {
                PhotoImportPicker { providers in
                    importPhotos(providers)
                }
                .ignoresSafeArea()
            }
            .overlay { importOverlay }
            .onAppear {
                guard !hasAutoLaunchedCamera else { return }
                hasAutoLaunchedCamera = true
                openCamera()
            }
            .alert("새 발표", isPresented: $showingNewAlert) {
                TextField("발표 제목", text: $newTitle)
                Button("만들기") {
                    store.addPresentation(title: newTitle)
                }
                Button("취소", role: .cancel) {}
            } message: {
                Text("발표 제목을 입력하세요.")
            }
            .alert("발표 제목 수정", isPresented: renameBinding) {
                TextField("발표 제목", text: $renameText)
                Button("저장") {
                    if let id = renamingID {
                        store.renamePresentation(id, to: renameText)
                    }
                }
                Button("취소", role: .cancel) {}
            } message: {
                Text("새 발표 제목을 입력하세요.")
            }
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(
            get: { renamingID != nil },
            set: { if !$0 { renamingID = nil } }
        )
    }

    private func startRename(_ presentation: Presentation) {
        renameText = presentation.title
        renamingID = presentation.id
    }

    // MARK: - 화면 내용

    @ViewBuilder
    private var content: some View {
        if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            searchResults
        } else if store.presentations.isEmpty {
            ContentUnavailableView(
                "발표가 없습니다",
                systemImage: "rectangle.on.rectangle.angled",
                description: Text("오른쪽 위 + 버튼으로 새 발표를 만들고\n장표를 촬영해 보세요.")
            )
        } else {
            presentationsList
        }
    }

    private var presentationsList: some View {
        List {
            ForEach(store.presentations) { presentation in
                NavigationLink(value: presentation.id) {
                    row(presentation)
                }
                .swipeActions(edge: .leading) {
                    Button {
                        startRename(presentation)
                    } label: {
                        Label("이름 변경", systemImage: "pencil")
                    }
                    .tint(.blue)
                }
                .contextMenu {
                    Button {
                        startRename(presentation)
                    } label: {
                        Label("이름 변경", systemImage: "pencil")
                    }
                }
            }
            .onDelete(perform: delete)
        }
    }

    // MARK: - 검색 결과

    @ViewBuilder
    private var searchResults: some View {
        let results = store.searchSlides(searchText)
        if results.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            List(results) { result in
                NavigationLink(value: SlideRoute(presentationID: result.presentationID, slideID: result.id)) {
                    searchRow(result)
                }
            }
        }
    }

    private func searchRow(_ result: SlideSearchResult) -> some View {
        HStack(spacing: 12) {
            Group {
                if let image = store.loadImage(result.slide.thumbFile) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle().fill(Color(.secondarySystemBackground))
                }
            }
            .frame(width: 54, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text("\(result.presentationTitle) · \(result.slideNumber)번")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(result.snippet.isEmpty ? "(텍스트 없음)" : result.snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 사진 가져오기

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
        }
    }

    /// 고른 사진들로 새 발표를 만들어 넣고, 처리가 끝나면 그 발표로 이동합니다.
    private func importPhotos(_ providers: [NSItemProvider]) {
        guard !providers.isEmpty else { return }
        let presentation = store.addPresentation(title: Store.defaultTitle())
        Task {
            await store.importImages(providers, to: presentation.id) { done, total in
                importProgress = (done, total)
            }
            importProgress = nil
            // 한 장도 못 넣었으면 빈 발표를 지운다.
            if store.presentation(presentation.id)?.slides.isEmpty ?? true {
                store.deletePresentation(presentation.id)
            } else {
                path.append(presentation.id)
            }
        }
    }

    // MARK: - 바로 촬영

    /// 카메라를 띄운다. 최근 발표의 마지막 촬영이 5분 이내면 그 발표에 이어 붙이고,
    /// 아니면 새 발표를 만든다.
    private func openCamera() {
        cameraCaptured = false
        if let recent = store.presentations.first,
           let lastTime = recent.slides.last?.createdAt,
           Date().timeIntervalSince(lastTime) < Self.groupingWindow {
            cameraPresentationID = recent.id
            cameraCreatedNew = false
        } else {
            let presentation = store.addPresentation(title: Store.defaultTitle())
            cameraPresentationID = presentation.id
            cameraCreatedNew = true
        }
        showingCamera = true
    }

    /// 촬영을 마치면 처리한다.
    /// - 촬영이 있었으면(처리 중이라 아직 슬라이드가 안 보여도) 그 발표 그리드로 이동한다.
    /// - 새로 만든 발표인데 한 장도 안 찍었으면 빈 발표를 지운다.
    /// - 기존 발표에 이어 찍으려다 안 찍었으면 그냥 목록으로 돌아간다(기존 장표는 보존).
    private func cameraFinished() {
        guard let id = cameraPresentationID else { return }
        cameraPresentationID = nil
        if cameraCaptured {
            path.append(id)
        } else if cameraCreatedNew {
            store.deletePresentation(id)
        }
    }

    private func row(_ presentation: Presentation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(presentation.title)
                .font(.headline)
            Text("\(Self.dateString(presentation.createdAt)) · 장표 \(presentation.slides.count)장")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func delete(at offsets: IndexSet) {
        let ids = offsets.map { store.presentations[$0].id }
        for id in ids {
            store.deletePresentation(id)
        }
    }

    private static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "yyyy. M. d. (E) HH:mm"
        return formatter.string(from: date)
    }
}
