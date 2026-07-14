import SwiftUI

/// 첫 화면 — 발표 목록
struct PresentationListView: View {

    @EnvironmentObject private var store: Store

    @State private var showingNewAlert = false
    @State private var newTitle = ""

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
            Group {
                if store.presentations.isEmpty {
                    ContentUnavailableView(
                        "발표가 없습니다",
                        systemImage: "rectangle.on.rectangle.angled",
                        description: Text("오른쪽 위 + 버튼으로 새 발표를 만들고\n장표를 촬영해 보세요.")
                    )
                } else {
                    List {
                        ForEach(store.presentations) { presentation in
                            NavigationLink(value: presentation.id) {
                                row(presentation)
                            }
                        }
                        .onDelete(perform: delete)
                    }
                }
            }
            .navigationTitle("장표스냅")
            .navigationDestination(for: UUID.self) { id in
                PresentationDetailView(presentationID: id)
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
                    Button {
                        newTitle = Store.defaultTitle()
                        showingNewAlert = true
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
