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

    func deleteSlide(_ slideID: UUID, from presentationID: UUID) {
        guard let pIndex = presentations.firstIndex(where: { $0.id == presentationID }),
              let sIndex = presentations[pIndex].slides.firstIndex(where: { $0.id == slideID }) else { return }
        deleteFiles(of: presentations[pIndex].slides[sIndex])
        presentations[pIndex].slides.remove(at: sIndex)
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
}
