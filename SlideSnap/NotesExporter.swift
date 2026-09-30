import Foundation

/// 발표를 다른 앱에서 이어 쓸 수 있는 파일로 내보낸다.
/// - Markdown(.zip): 노트 한 장 + images 폴더. Notion·Obsidian·Bear 등에서 가져오기로 연다.
/// - PowerPoint(.pptx): 장표 한 장당 슬라이드 한 장, 그때 한 말은 발표자 노트로. Keynote·Google Slides에서도 열린다.
enum NotesExporter {

    struct SlideExport {
        let number: Int
        let imageURL: URL
        /// 장표에서 인식한 글자
        let text: String?
        /// 그 장표를 보여 주던 동안 받아쓴 말
        let spoken: String?
    }

    @MainActor
    static func slides(of presentation: Presentation, only ids: Set<UUID>? = nil, store: Store) -> [SlideExport] {
        presentation.slides.enumerated().compactMap { index, slide in
            if let ids, !ids.contains(slide.id) { return nil }
            return SlideExport(
                number: index + 1,
                imageURL: store.imageURL(store.displayFile(for: slide)),
                text: slide.recognizedText?.trimmingCharacters(in: .whitespacesAndNewlines),
                spoken: presentation.transcriptText(for: slide)
            )
        }
    }

    // MARK: - Markdown

    static func makeMarkdownZip(
        title: String,
        date: Date,
        summary: PresentationSummary?,
        slides: [SlideExport]
    ) throws -> URL {
        var zip = ZipWriter()
        var md = "# \(title)\n\n"
        md += date.formatted(date: .long, time: .shortened) + "\n\n"

        if let summary {
            md += "## " + String(localized: "요약") + "\n\n"
            md += summary.overview + "\n\n"
            for point in summary.keyPoints { md += "- \(point)\n" }
            if !summary.keywords.isEmpty {
                md += "\n" + String(localized: "키워드") + ": " + summary.keywords.map { "`\($0)`" }.joined(separator: " ") + "\n"
            }
            md += "\n"
        }

        md += "## " + String(localized: "장표") + "\n\n"
        for slide in slides {
            let ext = slide.imageURL.pathExtension.isEmpty ? "jpg" : slide.imageURL.pathExtension.lowercased()
            let imagePath = String(format: "images/slide-%03d.%@", slide.number, ext)
            if let data = try? Data(contentsOf: slide.imageURL) {
                zip.addFile(path: imagePath, data: data)
            }
            md += "### \(slide.number)\n\n"
            md += "![\(String(localized: "장표 \(slide.number)"))](\(imagePath))\n\n"
            if let spoken = slide.spoken, !spoken.isEmpty {
                md += "**" + String(localized: "발표 내용") + "**\n\n" + spoken + "\n\n"
            }
            if let text = slide.text, !text.isEmpty {
                md += text.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "> \($0)" }
                    .joined(separator: "\n") + "\n\n"
            }
        }

        let base = sanitizeFileName(title)
        zip.addFile(path: base + ".md", data: Data(md.utf8))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(base + ".zip")
        try? FileManager.default.removeItem(at: url)
        try zip.write(to: url)
        return url
    }

    // MARK: - PowerPoint

    static func makePPTX(title: String, slides: [SlideExport]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(sanitizeFileName(title) + ".pptx")
        try? FileManager.default.removeItem(at: url)
        try PPTXExporter.makePPTX(
            title: title,
            slides: slides.map { PPTXExporter.SlideInput(imageURL: $0.imageURL, notes: $0.spoken) },
            outputURL: url
        )
        return url
    }

    private static func sanitizeFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")
        let cleaned = name
            .components(separatedBy: invalid)
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "slides" : cleaned
    }
}
