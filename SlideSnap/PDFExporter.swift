import UIKit

/// 발표의 보정된 장표들을 순서대로 묶어 PDF로 만듭니다.
enum PDFExporter {

    /// 페이지 폭 기준 (A4 가로 폭 포인트)
    private static let pageWidth: CGFloat = 842
    /// PDF에 넣기 전 이미지 축소 상한 (픽셀)
    private static let maxImageDimension: CGFloat = 2200

    static func makePDF(title: String, imageURLs: [URL]) -> URL? {
        guard !imageURLs.isEmpty else { return nil }

        let fileName = sanitizeFileName(title) + ".pdf"
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(x: 0, y: 0, width: pageWidth, height: pageWidth * 9 / 16)
        )

        do {
            try renderer.writePDF(to: outputURL) { context in
                var wroteAnyPage = false
                for url in imageURLs {
                    autoreleasepool {
                        guard let loaded = UIImage(contentsOfFile: url.path) else { return }
                        let image = loaded.downsampled(maxDimension: maxImageDimension)
                        let pageSize = Self.pageSize(for: image)
                        context.beginPage(withBounds: CGRect(origin: .zero, size: pageSize), pageInfo: [:])
                        image.draw(in: CGRect(origin: .zero, size: pageSize))
                        wroteAnyPage = true
                    }
                }
                if !wroteAnyPage {
                    context.beginPage()
                }
            }
            return outputURL
        } catch {
            return nil
        }
    }

    private static func pageSize(for image: UIImage) -> CGSize {
        guard image.size.width > 0 else { return CGSize(width: pageWidth, height: pageWidth * 9 / 16) }
        let scale = pageWidth / image.size.width
        return CGSize(width: pageWidth, height: max(1, image.size.height * scale))
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
