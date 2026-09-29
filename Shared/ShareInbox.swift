//
//  ShareInbox.swift
//  SlideSnap (앱 + 공유 익스텐션 공용)
//
//  사진 앱 등에서 "공유 → 장표스냅"으로 넘어온 사진을 앱이 받아 가기까지 잠시 담아 두는 수신함.
//  익스텐션은 앱의 Documents에 쓸 수 없으므로 App Group 컨테이너를 거친다.
//
//  수신함/<묶음 id>/ 아래에 사진 파일들과 manifest.json을 두고, manifest가 있는 묶음만
//  "다 옮겨진 묶음"으로 본다. 앱은 묶음을 발표로 만든 뒤 폴더째 지운다.
//

import Foundation
import ImageIO

enum ShareInbox {

    static let appGroupID = "group.com.leeo.slidesnap"

    /// 공유를 받은 뒤 앱을 여는 딥링크.
    static let openURL = URL(string: "slidesnap://import")!

    /// 공유받은 사진 묶음 하나의 설명서.
    struct Manifest: Codable {
        var id: UUID
        /// 발표 제목(비어 있으면 앱이 기본 제목을 붙인다).
        var title: String
        /// 넣을 순서대로 정렬된 사진 파일명(묶음 폴더 기준).
        var files: [String]
        /// 사진마다의 촬영 시각(없으면 nil). files와 같은 순서.
        var capturedAt: [Date?]
        /// 가독성 보정(대비·그림자)을 모든 장표에 적용할지.
        var enhance: Bool
        var createdAt: Date
    }

    static var containerURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("ShareInbox", isDirectory: true)
    }

    static func batchURL(_ id: UUID) -> URL? {
        containerURL?.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private static let manifestName = "manifest.json"

    // MARK: - 익스텐션 쪽: 쓰기

    /// 묶음 폴더를 새로 만든다.
    static func makeBatchDirectory(_ id: UUID) throws -> URL {
        guard let url = batchURL(id) else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 설명서를 마지막에 써서 묶음을 "완성"으로 표시한다.
    static func commit(_ manifest: Manifest) throws {
        guard let dir = batchURL(manifest.id) else { throw CocoaError(.fileNoSuchFile) }
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: dir.appendingPathComponent(manifestName), options: .atomic)
    }

    static func discard(_ id: UUID) {
        guard let url = batchURL(id) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - 앱 쪽: 읽기

    /// 완성된 묶음들을 오래된 것부터 돌려준다.
    static func pendingManifests() -> [Manifest] {
        guard let root = containerURL,
              let dirs = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
              ) else { return [] }
        let decoder = JSONDecoder()
        return dirs
            .compactMap { dir -> Manifest? in
                guard let data = try? Data(contentsOf: dir.appendingPathComponent(manifestName)) else { return nil }
                return try? decoder.decode(Manifest.self, from: data)
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: - 사진 정보

    /// 사진 파일의 EXIF 촬영 시각. 없으면 nil.
    static func captureDate(of url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let raw = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? (exif?[kCGImagePropertyExifDateTimeDigitized] as? String)
            ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String)
        guard let raw else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: raw)
    }

    /// 사진들의 촬영 날짜로 만든 기본 제목. 촬영 시각이 하나도 없으면 오늘 날짜.
    static func defaultTitle(for dates: [Date?]) -> String {
        PresentationNaming.title(for: dates.compactMap { $0 }.min() ?? Date())
    }
}

/// 발표 기본 제목("9월 29일 발표" / "Sep 29 Slides") — 앱과 공유 익스텐션이 같은 규칙을 쓴다.
enum PresentationNaming {
    static func title(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        let day = formatter.string(from: date)
        return String(localized: "\(day) 발표")
    }
}
