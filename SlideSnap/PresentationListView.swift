import SwiftUI
import LeeoKit

/// 첫 화면 — 발표 목록
struct PresentationListView: View {

    @EnvironmentObject private var store: Store
    @EnvironmentObject private var feedbackPrompt: FeedbackPromptManager
    @EnvironmentObject private var router: AppRouter

    @Environment(\.scenePhase) private var scenePhase

    @State private var showingNewAlert = false
    @State private var newTitle = ""

    @State private var showingFeedback = false
    @State private var showingProfile = false
    @State private var feedbackInitialType: FeedbackType = .improvement

    /// 목록/그리드 보기 선택(기억됨). 그리드는 썸네일 미리보기를 보여준다.
    @AppStorage("presentationsGridView") private var isGridView = false

    @State private var renamingID: UUID?
    @State private var renameText = ""

    /// 여러 발표를 골라 하나로 합치는 선택 모드.
    @State private var isSelecting = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var showingMergeConfirm = false

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
            .navigationTitle(isSelecting ? "\(selectedIDs.count)개 선택" : "")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "장표 텍스트·제목 검색")
            .navigationDestination(for: UUID.self) { id in
                PresentationDetailView(presentationID: id)
            }
            .navigationDestination(for: SlideRoute.self) { route in
                SlideDetailView(presentationID: route.presentationID, slideID: route.slideID)
            }
            .toolbar { toolbarContent }
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
            .sheet(isPresented: $showingFeedback) {
                FeedbackView(initialType: feedbackInitialType)
            }
            .sheet(isPresented: $showingProfile) {
                ProfileView()
            }
            .alert("사용하시면서 어떠세요?", isPresented: nudgeBinding) {
                Button("의견 남기기") {
                    feedbackPrompt.dismiss()
                    feedbackInitialType = .improvement
                    showingFeedback = true
                }
                Button("다음에 할게요", role: .cancel) {
                    feedbackPrompt.dismiss()
                }
                Button("다시 묻지 않기", role: .destructive) {
                    feedbackPrompt.optOut()
                }
            } message: {
                Text("불편한 점이나 개선했으면 하는 점이 있으신가요?\n작은 의견도 앱을 더 좋게 만드는 데 큰 도움이 돼요.")
            }
            .onAppear {
                guard !hasAutoLaunchedCamera else { return }
                hasAutoLaunchedCamera = true
                openCamera()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    feedbackPrompt.registerLaunch()
                }
            }
            .onChange(of: router.cameraLaunchRequest) { _, _ in
                openCamera()   // 위젯 등 딥링크로 카메라 즉시 실행
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
            .alert("발표 합치기", isPresented: $showingMergeConfirm) {
                Button("합치기") { mergeSelected() }
                Button("취소", role: .cancel) {}
            } message: {
                Text("선택한 \(selectedIDs.count)개 발표를 하나로 합칩니다.\n장표는 목록 순서대로 이어 붙고, 되돌릴 수 없어요.")
            }
        }
    }

    // MARK: - 툴바

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                Button("취소") { exitSelection() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingMergeConfirm = true
                } label: {
                    Text(selectedIDs.count >= 2 ? "합치기 (\(selectedIDs.count))" : "합치기")
                        .fontWeight(.semibold)
                }
                .disabled(selectedIDs.count < 2)
            }
        } else {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button {
                        showingProfile = true
                    } label: {
                        Label("내 정보", systemImage: "person.crop.circle")
                    }
                    Button {
                        feedbackInitialType = .improvement
                        showingFeedback = true
                    } label: {
                        Label("피드백 보내기", systemImage: "paperplane")
                    }
                    if store.presentations.count >= 2 {
                        Divider()
                        Button {
                            enterSelection()
                        } label: {
                            Label("발표 합치기", systemImage: "arrow.triangle.merge")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            if !store.presentations.isEmpty {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { isGridView.toggle() }
                    } label: {
                        Image(systemName: isGridView ? "list.bullet" : "square.grid.2x2")
                    }
                    .accessibilityLabel(isGridView ? "목록으로 보기" : "그리드로 보기")
                }
            }
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
    }

    // MARK: - 발표 선택·병합

    private func enterSelection() {
        selectedIDs = []
        withAnimation(.easeInOut(duration: 0.2)) { isSelecting = true }
    }

    private func exitSelection() {
        withAnimation(.easeInOut(duration: 0.2)) { isSelecting = false }
        selectedIDs = []
    }

    private func toggleSelect(_ id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    /// 선택한 발표들을 하나로 합치고, 합쳐진 발표로 이동한다.
    private func mergeSelected() {
        guard let merged = store.mergePresentations(selectedIDs) else { return }
        LeeoUsageReporter(spec: SlideSnapSpec.self).logEventInBackground("merge")
        exitSelection()
        path.append(merged)
    }

    /// 선택 모드에서 각 발표 앞에 붙는 체크 표시.
    @ViewBuilder
    private func selectionMark(_ id: UUID) -> some View {
        let on = selectedIDs.contains(id)
        Image(systemName: on ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(on ? Color.accentColor : Color.secondary)
    }

    /// 넛지는 목록 화면에 머물러 있고(카메라·다른 시트가 없고) 아직 노출 대상일 때만 띄운다.
    private var nudgeBinding: Binding<Bool> {
        Binding(
            get: {
                feedbackPrompt.shouldPrompt
                    && !showingCamera && !showingFeedback && !showingProfile
                    && !showingNewAlert && path.isEmpty
            },
            set: { if !$0 { feedbackPrompt.dismiss() } }
        )
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
        } else if isGridView {
            presentationsGrid
        } else {
            presentationsList
        }
    }

    // MARK: - 그리드 보기 (썸네일)

    private var presentationsGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
                ForEach(store.presentations) { presentation in
                    if isSelecting {
                        Button {
                            toggleSelect(presentation.id)
                        } label: {
                            presentationCard(presentation)
                                .overlay(alignment: .topLeading) {
                                    selectionMark(presentation.id)
                                        .padding(6)
                                        .background(.black.opacity(0.35), in: Circle())
                                        .padding(6)
                                }
                                .overlay {
                                    if selectedIDs.contains(presentation.id) {
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(Color.accentColor, lineWidth: 3)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    } else {
                        NavigationLink(value: presentation.id) {
                            presentationCard(presentation)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                startRename(presentation)
                            } label: {
                                Label("이름 변경", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                store.deletePresentation(presentation.id)
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

    private func presentationCard(_ presentation: Presentation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.secondarySystemBackground))
                if let cover = coverImage(presentation) {
                    Image(uiImage: cover)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "rectangle.on.rectangle.angled")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 130)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .bottomTrailing) {
                Text("\(presentation.slides.count)장")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(6)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(Self.dateString(presentation.createdAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    /// 발표 대표 썸네일 — 첫 장표의 썸네일.
    private func coverImage(_ presentation: Presentation) -> UIImage? {
        guard let first = presentation.slides.first else { return nil }
        return store.loadImage(first.thumbFile)
    }

    // MARK: - 목록 보기

    private var presentationsList: some View {
        List {
            ForEach(store.presentations) { presentation in
                if isSelecting {
                    Button {
                        toggleSelect(presentation.id)
                    } label: {
                        HStack(spacing: 12) {
                            selectionMark(presentation.id)
                            row(presentation)
                        }
                    }
                    .buttonStyle(.plain)
                } else {
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
            }
            .onDelete(perform: isSelecting ? nil : delete)
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
        LeeoUsageReporter(spec: SlideSnapSpec.self).logEventInBackground("photo_import")
        // 한 장이라도 들어와야 목록에 올라가도록 초안으로 시작한다(0장 발표 깜빡임 방지).
        let presentation = store.beginDraftPresentation(title: Store.defaultTitle())
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
        guard !showingCamera else { return }   // 이미 촬영 중이면(딥링크 중복 등) 무시
        cameraCaptured = false
        if let recent = store.presentations.first,
           let lastTime = recent.slides.last?.createdAt,
           Date().timeIntervalSince(lastTime) < Self.groupingWindow {
            cameraPresentationID = recent.id
            cameraCreatedNew = false
        } else {
            // 아직 목록에 올리지 않는다. 한 장도 안 찍고 닫으면 목록에 흔적이 남지 않도록.
            let presentation = store.beginDraftPresentation(title: Store.defaultTitle())
            cameraPresentationID = presentation.id
            cameraCreatedNew = true
        }
        showingCamera = true
    }

    /// 촬영을 마치면 처리한다.
    /// - 촬영이 있었으면(처리 중이라 아직 슬라이드가 안 보여도) 초안을 목록에 올리고 그 발표로 이동한다.
    ///   목록에 올리는 것과 화면 이동이 같은 갱신에 일어나므로 "0장" 행이 보이지 않는다.
    /// - 새로 만든 발표인데 한 장도 안 찍었으면 초안을 그냥 버린다(목록에 올린 적이 없다).
    /// - 기존 발표에 이어 찍으려다 안 찍었으면 그냥 목록으로 돌아간다(기존 장표는 보존).
    private func cameraFinished() {
        guard let id = cameraPresentationID else { return }
        cameraPresentationID = nil
        if cameraCaptured {
            store.promoteDraft(id)
            path.append(id)
        } else if cameraCreatedNew {
            store.discardDraft(id)
        }
    }

    private func row(_ presentation: Presentation) -> some View {
        HStack(spacing: 12) {
            Group {
                if let cover = coverImage(presentation) {
                    Image(uiImage: cover)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Rectangle().fill(Color(.secondarySystemBackground))
                        Image(systemName: "rectangle.on.rectangle.angled")
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.title)
                    .font(.headline)
                Text("\(Self.dateString(presentation.createdAt)) · 장표 \(presentation.slides.count)장")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
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
