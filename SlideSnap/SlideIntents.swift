//
//  SlideIntents.swift
//  SlideSnap
//
//  장표를 Siri · Spotlight · 단축어가 알아보게 한다.
//
//  - Spotlight: 장표마다 찍힌 글자(OCR)와 내 메모를 싣는다. 단어 하나로 그 장표가 썸네일과 함께 뜬다.
//  - "장표스냅에서 슬라이드 찍어줘": 카메라를 바로 연다.
//  - "장표스냅에서 장표 찾아줘": 무엇을 찾을지 묻고, 맞는 장표들을 보여 준다. 누르면 그 장표가 열린다.
//
//  읽기는 Store 인스턴스를 거치지 않고 store.json 을 바로 읽는다. 인텐트는 화면 없이도 돌기 때문이다.
//  색인(IndexedEntity)은 iOS 18 부터라 그 부분만 나눠 둔다.
//

import AppIntents
import CoreSpotlight
import Foundation

// MARK: - 장표

struct SlideEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("장표", comment: "Siri/Spotlight: one captured slide")
    )
    static let defaultQuery = SlideQuery()

    let id: UUID
    let presentationID: UUID
    let presentationTitle: String
    let number: Int
    /// 내 메모와 장표 글자. 검색 · 색인에 쓴다.
    let text: String
    let thumbnailURL: URL?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(presentationTitle)",
            subtitle: LocalizedStringResource("\(number)번째 장표", comment: "Siri/Spotlight subtitle. Argument is the slide number"),
            image: thumbnailURL.map { .init(url: $0) }
        )
    }

    static func all() -> [SlideEntity] {
        let images = SlideLibrary.imagesDirectory
        return SlideLibrary.read().flatMap { presentation in
            presentation.slides.enumerated().map { index, slide in
                SlideEntity(
                    id: slide.id,
                    presentationID: presentation.id,
                    presentationTitle: presentation.title,
                    number: index + 1,
                    text: [slide.memo ?? "", slide.recognizedText ?? ""].filter { !$0.isEmpty }.joined(separator: "\n"),
                    thumbnailURL: images.appendingPathComponent(slide.thumbFile)
                )
            }
        }
    }
}

@available(iOS 18.0, *)
extension SlideEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let set = defaultAttributeSet
        set.textContent = text
        set.thumbnailURL = thumbnailURL
        return set
    }
}

struct SlideQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [SlideEntity] {
        let wanted = Set(identifiers)
        return SlideEntity.all().filter { wanted.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [SlideEntity] {
        SlideLibrary.search(string)
    }

    /// 가장 최근 발표의 장표부터.
    func suggestedEntities() async throws -> [SlideEntity] {
        Array(SlideEntity.all().reversed().prefix(20))
    }
}

// MARK: - 장표 찾기

struct FindSlidesIntent: AppIntent {
    static let title = LocalizedStringResource("장표 찾기", comment: "Siri: find slides by a word")
    static let description = IntentDescription(
        LocalizedStringResource("장표에 찍힌 글자와 내 메모에서 단어를 찾습니다.", comment: "Siri: find slides description")
    )

    @Parameter(title: LocalizedStringResource("찾을 말", comment: "Siri: search word parameter"),
               description: LocalizedStringResource("장표에 찍힌 글자나 내 메모에서 찾을 단어", comment: "Siri: search word parameter description"),
               requestValueDialog: IntentDialog(LocalizedStringResource("어떤 말을 찾을까요?", comment: "Siri: ask what to search")))
    var query: String

    func perform() async throws -> some IntentResult & ReturnsValue<[SlideEntity]> & ProvidesDialog {
        let found = SlideLibrary.search(query)
        let dialog = found.isEmpty
            ? IntentDialog(LocalizedStringResource("‘\(query)’이 들어간 장표가 없어요.", comment: "Siri: no slide found. Argument is the search word"))
            : IntentDialog(LocalizedStringResource("‘\(query)’이 들어간 장표 \(found.count)장을 찾았어요.", comment: "Siri: slides found. Arguments: search word, count"))
        return .result(value: found, dialog: dialog)
    }
}

/// 장표를 연다. Spotlight · Siri 결과를 누르면 여기로 온다.
struct OpenSlideIntent: OpenIntent {
    static let title = LocalizedStringResource("장표 열기", comment: "Siri/Spotlight: open a slide")
    static let description = IntentDescription(
        LocalizedStringResource("찍어 둔 장표를 앱에서 엽니다.", comment: "Siri: open slide description")
    )

    @Parameter(title: LocalizedStringResource("장표", comment: "Siri: slide parameter"),
               description: LocalizedStringResource("열어 볼 장표", comment: "Siri: slide parameter description"))
    var target: SlideEntity

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.slideRequest = SlideRoute(presentationID: target.presentationID, slideID: target.id)
        return .result()
    }
}

// MARK: - 찍기

struct CaptureSlidesIntent: AppIntent {
    static let title = LocalizedStringResource("장표 찍기", comment: "Siri: open the camera to capture slides")
    static let description = IntentDescription(
        LocalizedStringResource("카메라를 바로 열어 장표를 찍습니다.", comment: "Siri: capture slides description")
    )
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.cameraLaunchRequest &+= 1
        return .result()
    }
}

// MARK: - Siri 문구

struct SlideSnapShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CaptureSlidesIntent(),
            phrases: [
                "Capture slides with \(.applicationName)",
                "Scan a slide with \(.applicationName)",
                "Open \(.applicationName) camera"
            ],
            shortTitle: "Capture Slides",
            systemImageName: "camera.viewfinder"
        )
        AppShortcut(
            intent: FindSlidesIntent(),
            phrases: [
                "Find a slide in \(.applicationName)",
                "Search slides in \(.applicationName)"
            ],
            shortTitle: "Find Slides",
            systemImageName: "text.magnifyingglass"
        )
    }
}

// MARK: - 저장된 발표 읽기 · 색인

enum SlideLibrary {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }
    static var imagesDirectory: URL { documents.appendingPathComponent("Images", isDirectory: true) }

    /// store.json 을 그대로 읽는다. 못 읽으면 빈 목록 (Store 와 같은 파일, 같은 형식).
    static func read() -> [Presentation] {
        guard let data = try? Data(contentsOf: documents.appendingPathComponent("store.json")) else { return [] }
        return (try? JSONDecoder().decode([Presentation].self, from: data)) ?? []
    }

    /// 발표 제목 · 내 메모 · 장표 글자에서 찾는다(대소문자 · 악센트 무시). 앱 안 검색과 같은 기준.
    static func search(_ raw: String) -> [SlideEntity] {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        func matches(_ s: String) -> Bool { s.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        return SlideEntity.all().filter { matches($0.presentationTitle) || matches($0.text) }
    }

    private static var pending: Task<Void, Never>?

    /// 저장할 때마다 부른다. 잇달아 저장하면 마지막 한 번만 색인한다.
    @MainActor
    static func scheduleReindex() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await reindex()
        }
    }

    static func reindex() async {
        guard #available(iOS 18.0, *) else { return }
        let index = CSSearchableIndex.default()
        try? await index.deleteAppEntities(ofType: SlideEntity.self)
        try? await index.indexAppEntities(SlideEntity.all())
    }
}
