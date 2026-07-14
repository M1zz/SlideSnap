import SwiftUI

/// 앱 데이터 저장소.
/// 메타데이터는 Documents/store.json, 이미지는 Documents/Images/ 아래에 보관합니다.
@MainActor
final class Store: ObservableObject {

    @Published private(set) var presentations: [Presentation] = []

    private let fileManager = FileManager.default

    private var documentsURL: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private var storeFileURL: URL {
        documentsURL.appendingPathComponent("store.json")
    }

    var imagesDirectoryURL: URL {
        let url = documentsURL.appendingPathComponent("Images", isDirectory: true)
        if !fileManager.fileExists(atPath: url.path) {
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    init() {
        load()
        backfillOCR()
    }

    // MARK: - 영속화

    private func load() {
        guard let data = try? Data(contentsOf: storeFileURL) else { return }
        if let decoded = try? JSONDecoder().decode([Presentation].self, from: data) {
            presentations = decoded
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(presentations) else { return }
        try? data.write(to: storeFileURL, options: .atomic)
    }

    // MARK: - 발표

    static func defaultTitle() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "M월 d일 발표"
        return formatter.string(from: Date())
    }

    @discardableResult
    func addPresentation(title: String) -> Presentation {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let presentation = Presentation(
            id: UUID(),
            title: trimmed.isEmpty ? Self.defaultTitle() : trimmed,
            createdAt: Date(),
            slides: []
        )
        presentations.insert(presentation, at: 0)
        persist()
        return presentation
    }

    func renamePresentation(_ id: UUID, to title: String) {
        guard let index = presentations.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        presentations[index].title = trimmed
        persist()
    }

    func deletePresentation(_ id: UUID) {
        guard let index = presentations.firstIndex(where: { $0.id == id }) else { return }
        for slide in presentations[index].slides {
            deleteFiles(of: slide)
        }
        presentations.remove(at: index)
        persist()
    }

    func presentation(_ id: UUID) -> Presentation? {
        presentations.first { $0.id == id }
    }

    // MARK: - 장표

    /// 촬영한 사진을 감지·보정·저장. 무거운 처리는 백그라운드에서 수행됩니다.
    /// - Parameter detectedQuad: 촬영 화면에서 실시간으로 잡아 둔 모서리(있으면 그대로 사용).
    func addSlide(image: UIImage, to presentationID: UUID, detectedQuad: Quad? = nil) async {
        let directory = imagesDirectoryURL
        let slide = await Task.detached(priority: .userInitiated) {
            SlideFactory.makeSlide(from: image, in: directory, detectedQuad: detectedQuad)
        }.value

        guard let slide,
              let index = presentations.firstIndex(where: { $0.id == presentationID }) else { return }
        presentations[index].slides.append(slide)
        persist()
    }

    /// 사진 앱에서 고른 이미지들을 순서대로 감지·보정해 발표에 넣습니다.
    /// 메모리를 아끼려고 한 장씩 로드→처리→해제하며, 진행 상황을 콜백으로 알립니다.
    func importImages(
        _ providers: [NSItemProvider],
        to presentationID: UUID,
        onProgress: @escaping (_ done: Int, _ total: Int) -> Void
    ) async {
        let total = providers.count
        onProgress(0, total)
        for (index, provider) in providers.enumerated() {
            if let image = await Self.loadUIImage(from: provider) {
                await addSlide(image: image, to: presentationID)
            }
            onProgress(index + 1, total)
        }
    }

    private static func loadUIImage(from provider: NSItemProvider) async -> UIImage? {
        guard provider.canLoadObject(ofClass: UIImage.self) else { return nil }
        return await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                continuation.resume(returning: object as? UIImage)
            }
        }
    }

    func deleteSlide(_ slideID: UUID, from presentationID: UUID) {
        guard let pIndex = presentations.firstIndex(where: { $0.id == presentationID }),
              let sIndex = presentations[pIndex].slides.firstIndex(where: { $0.id == slideID }) else { return }
        deleteFiles(of: presentations[pIndex].slides[sIndex])
        presentations[pIndex].slides.remove(at: sIndex)
        persist()
    }

    /// 선택한 장표들을 한 번에 삭제합니다.
    func deleteSlides(_ slideIDs: Set<UUID>, from presentationID: UUID) {
        guard !slideIDs.isEmpty,
              let pIndex = presentations.firstIndex(where: { $0.id == presentationID }) else { return }
        for slide in presentations[pIndex].slides where slideIDs.contains(slide.id) {
            deleteFiles(of: slide)
        }
        presentations[pIndex].slides.removeAll { slideIDs.contains($0.id) }
        persist()
    }

    /// 드래그로 장표 순서를 바꿉니다. `slideID`를 `targetID` 자리로 옮깁니다.
    func moveSlide(_ slideID: UUID, before targetID: UUID, in presentationID: UUID) {
        guard slideID != targetID,
              let pIndex = presentations.firstIndex(where: { $0.id == presentationID }),
              let from = presentations[pIndex].slides.firstIndex(where: { $0.id == slideID }) else { return }
        let slide = presentations[pIndex].slides.remove(at: from)
        let insertAt = presentations[pIndex].slides.firstIndex(where: { $0.id == targetID })
            ?? presentations[pIndex].slides.count
        presentations[pIndex].slides.insert(slide, at: insertAt)
        persist()
    }

    /// List의 onMove(오프셋 기반)로 장표 순서를 바꿉니다.
    func moveSlides(in presentationID: UUID, fromOffsets source: IndexSet, toOffset destination: Int) {
        guard let pIndex = presentations.firstIndex(where: { $0.id == presentationID }) else { return }
        presentations[pIndex].slides.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    /// 모서리를 수동으로 바꿔 다시 보정합니다. quad가 nil이면 보정 해제(원본 사용).
    func updateCorners(_ quad: Quad?, slideID: UUID, presentationID: UUID) async {
        guard let pIndex = presentations.firstIndex(where: { $0.id == presentationID }),
              let sIndex = presentations[pIndex].slides.firstIndex(where: { $0.id == slideID }) else { return }

        let slide = presentations[pIndex].slides[sIndex]
        let directory = imagesDirectoryURL
        let updated = await Task.detached(priority: .userInitiated) {
            SlideFactory.reprocess(slide: slide, quad: quad, in: directory)
        }.value

        guard let updated,
              let pIdx = presentations.firstIndex(where: { $0.id == presentationID }),
              let sIdx = presentations[pIdx].slides.firstIndex(where: { $0.id == slideID }) else { return }
        presentations[pIdx].slides[sIdx] = updated
        persist()
    }

    // MARK: - 이미지 파일

    func imageURL(_ fileName: String) -> URL {
        imagesDirectoryURL.appendingPathComponent(fileName)
    }

    func loadImage(_ fileName: String) -> UIImage? {
        UIImage(contentsOfFile: imageURL(fileName).path)
    }

    private func deleteFiles(of slide: Slide) {
        for file in [slide.originalFile, slide.correctedFile, slide.thumbFile] {
            try? fileManager.removeItem(at: imageURL(file))
        }
    }

    // MARK: - OCR 텍스트 검색

    /// 모든 발표의 장표를 대상으로 제목/인식 텍스트에서 검색합니다.
    func searchSlides(_ rawQuery: String) -> [SlideSearchResult] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }

        var results: [SlideSearchResult] = []
        for presentation in presentations {
            let titleMatches = presentation.title.lowercased().contains(query)
            for (index, slide) in presentation.slides.enumerated() {
                let text = slide.recognizedText ?? ""
                let textMatches = text.lowercased().contains(query)
                guard titleMatches || textMatches else { continue }
                results.append(
                    SlideSearchResult(
                        id: slide.id,
                        presentationID: presentation.id,
                        presentationTitle: presentation.title,
                        slideNumber: index + 1,
                        slide: slide,
                        snippet: Self.snippet(from: text, matching: query)
                    )
                )
            }
        }
        return results
    }

    /// 인식 텍스트에서 검색어 주변을 잘라 미리보기 문구를 만듭니다.
    private static func snippet(from text: String, matching query: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard let range = flat.range(of: query, options: .caseInsensitive) else {
            return String(flat.prefix(60))
        }
        let start = flat.index(range.lowerBound, offsetBy: -25, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(range.upperBound, offsetBy: 40, limitedBy: flat.endIndex) ?? flat.endIndex
        var s = String(flat[start..<end]).trimmingCharacters(in: .whitespaces)
        if start != flat.startIndex { s = "…" + s }
        if end != flat.endIndex { s += "…" }
        return s
    }

    /// 기존 데이터 중 아직 OCR을 돌리지 않은 장표(recognizedText == nil)를 백그라운드에서 인식합니다.
    private func backfillOCR() {
        let pending: [(pID: UUID, sID: UUID, file: String)] = presentations.flatMap { presentation in
            presentation.slides
                .filter { $0.recognizedText == nil }
                .map { (presentation.id, $0.id, $0.correctedFile) }
        }
        guard !pending.isEmpty else { return }
        let directory = imagesDirectoryURL

        Task.detached(priority: .utility) { [weak self] in
            for item in pending {
                let url = directory.appendingPathComponent(item.file)
                guard let image = UIImage(contentsOfFile: url.path) else { continue }
                let text = ImageProcessor.recognizeText(in: image)
                await MainActor.run {
                    self?.setRecognizedText(text, slideID: item.sID, presentationID: item.pID)
                }
            }
        }
    }

    private func setRecognizedText(_ text: String, slideID: UUID, presentationID: UUID) {
        guard let pIndex = presentations.firstIndex(where: { $0.id == presentationID }),
              let sIndex = presentations[pIndex].slides.firstIndex(where: { $0.id == slideID }) else { return }
        presentations[pIndex].slides[sIndex].recognizedText = text
        persist()
    }
}

/// 텍스트 검색 결과 한 건 (장표 하나).
struct SlideSearchResult: Identifiable {
    let id: UUID
    let presentationID: UUID
    let presentationTitle: String
    let slideNumber: Int
    let slide: Slide
    let snippet: String
}
