import UIKit

/// PDF 페이지당 장표 배치 방식.
enum PDFLayout: Identifiable {
    case one    // 한 장씩 (원본 비율 유지, 크게 보기)
    case two    // 두 장씩 (복습용)
    case four   // 네 장씩 (요약/손필기용)

    var id: Int { perPage }
    var perPage: Int {
        switch self {
        case .one: return 1
        case .two: return 2
        case .four: return 4
        }
    }

    var label: String {
        switch self {
        case .one: return "한 장씩 (크게 보기)"
        case .two: return "두 장씩 (복습용)"
        case .four: return "네 장씩 (요약용)"
        }
    }
}

/// 발표의 보정된 장표들을 순서대로 묶어 복습용 PDF로 만듭니다.
/// 각 장표에는 번호가 붙고, 여러 장 레이아웃은 A4 세로 페이지에 격자로 배치됩니다.
enum PDFExporter {

    /// 페이지 폭 기준 (A4 가로 폭 포인트) — 한 장씩 레이아웃에서 사용
    private static let pageWidth: CGFloat = 842
    /// A4 세로 페이지 (포인트, 72dpi) — 여러 장 레이아웃에서 사용
    private static let a4Portrait = CGSize(width: 595, height: 842)
    /// PDF에 넣기 전 이미지 축소 상한 (픽셀)
    private static let maxImageDimension: CGFloat = 2200

    static func makePDF(title: String, imageURLs: [URL], layout: PDFLayout = .one) -> URL? {
        guard !imageURLs.isEmpty else { return nil }

        let fileName = sanitizeFileName(title) + ".pdf"
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: title]
        // 렌더러 bounds는 첫 페이지 기본값일 뿐, 실제 페이지는 beginPage로 지정합니다.
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(origin: .zero, size: a4Portrait), format: format
        )

        do {
            try renderer.writePDF(to: outputURL) { context in
                if layout == .one {
                    drawOnePerPage(context: context, title: title, imageURLs: imageURLs)
                } else {
                    drawGrid(context: context, title: title, imageURLs: imageURLs, perPage: layout.perPage)
                }
            }
            return outputURL
        } catch {
            return nil
        }
    }

    // MARK: - 한 장씩 (원본 비율, 크게)

    private static func drawOnePerPage(context: UIGraphicsPDFRendererContext, title: String, imageURLs: [URL]) {
        var wroteAnyPage = false
        for (index, url) in imageURLs.enumerated() {
            autoreleasepool {
                guard let loaded = UIImage(contentsOfFile: url.path) else { return }
                let image = loaded.downsampled(maxDimension: maxImageDimension)
                let pageSize = onePageSize(for: image)
                context.beginPage(withBounds: CGRect(origin: .zero, size: pageSize), pageInfo: [:])
                image.draw(in: CGRect(origin: .zero, size: pageSize))
                drawBadge("\(index + 1)", in: CGRect(origin: .zero, size: pageSize))
                wroteAnyPage = true
            }
        }
        if !wroteAnyPage { context.beginPage() }
    }

    private static func onePageSize(for image: UIImage) -> CGSize {
        guard image.size.width > 0 else { return CGSize(width: pageWidth, height: pageWidth * 9 / 16) }
        let scale = pageWidth / image.size.width
        return CGSize(width: pageWidth, height: max(1, image.size.height * scale))
    }

    // MARK: - 여러 장 격자 (복습/요약용)

    private static func drawGrid(context: UIGraphicsPDFRendererContext, title: String, imageURLs: [URL], perPage: Int) {
        let page = a4Portrait
        let margin: CGFloat = 28
        let headerHeight: CGFloat = 30
        let gutter: CGFloat = 16
        let numberHeight: CGFloat = 14

        // 열/행 구성: 2장 → 1열 2행, 4장 → 2열 2행
        let columns = perPage == 2 ? 1 : 2
        let rows = 2

        let contentTop = margin + headerHeight
        let contentWidth = page.width - margin * 2
        let contentHeight = page.height - contentTop - margin
        let cellWidth = (contentWidth - gutter * CGFloat(columns - 1)) / CGFloat(columns)
        let cellHeight = (contentHeight - gutter * CGFloat(rows - 1)) / CGFloat(rows)

        let totalPages = Int(ceil(Double(imageURLs.count) / Double(perPage)))

        for pageIndex in 0..<max(totalPages, 1) {
            context.beginPage(withBounds: CGRect(origin: .zero, size: page), pageInfo: [:])
            drawHeader(title: title, page: pageIndex + 1, of: totalPages, in: page, margin: margin)

            for slot in 0..<perPage {
                let slideIndex = pageIndex * perPage + slot
                guard slideIndex < imageURLs.count else { break }

                let col = slot % columns
                let row = slot / columns
                let cellX = margin + CGFloat(col) * (cellWidth + gutter)
                let cellY = contentTop + CGFloat(row) * (cellHeight + gutter)
                let imageArea = CGRect(x: cellX, y: cellY, width: cellWidth, height: cellHeight - numberHeight)

                autoreleasepool {
                    guard let loaded = UIImage(contentsOfFile: imageURLs[slideIndex].path) else { return }
                    let image = loaded.downsampled(maxDimension: maxImageDimension)
                    let rect = aspectFitRect(imageSize: image.size, in: imageArea)
                    image.draw(in: rect)
                    // 이미지 아래 가운데에 장표 번호
                    drawNumberLabel(
                        "\(slideIndex + 1)",
                        centerX: imageArea.midX,
                        y: imageArea.maxY + 1,
                        width: cellWidth
                    )
                }
            }
        }
    }

    private static func drawHeader(title: String, page: Int, of total: Int, in pageSize: CGSize, margin: CGFloat) {
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: 13),
            .foregroundColor: UIColor.black
        ]
        let pageAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11),
            .foregroundColor: UIColor.gray
        ]
        let titleString = title as NSString
        titleString.draw(at: CGPoint(x: margin, y: margin), withAttributes: titleAttrs)

        let pageText = "\(page) / \(max(total, 1))" as NSString
        let size = pageText.size(withAttributes: pageAttrs)
        pageText.draw(at: CGPoint(x: pageSize.width - margin - size.width, y: margin + 1), withAttributes: pageAttrs)

        // 헤더 아래 구분선
        let line = UIBezierPath()
        line.move(to: CGPoint(x: margin, y: margin + 22))
        line.addLine(to: CGPoint(x: pageSize.width - margin, y: margin + 22))
        UIColor(white: 0.85, alpha: 1).setStroke()
        line.lineWidth = 0.5
        line.stroke()
    }

    private static func drawNumberLabel(_ text: String, centerX: CGFloat, y: CGFloat, width: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: UIColor.darkGray
        ]
        let string = text as NSString
        let size = string.size(withAttributes: attrs)
        string.draw(at: CGPoint(x: centerX - size.width / 2, y: y), withAttributes: attrs)
    }

    /// 한 장씩 레이아웃에서 페이지 모서리에 붙는 번호 배지.
    private static func drawBadge(_ text: String, in pageRect: CGRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: 15),
            .foregroundColor: UIColor.white
        ]
        let string = text as NSString
        let textSize = string.size(withAttributes: attrs)
        let padding: CGFloat = 7
        let badgeSize = CGSize(width: max(textSize.width + padding * 2, 26), height: textSize.height + padding)
        let badgeRect = CGRect(
            x: pageRect.maxX - badgeSize.width - 14,
            y: pageRect.maxY - badgeSize.height - 14,
            width: badgeSize.width,
            height: badgeSize.height
        )
        let bg = UIBezierPath(roundedRect: badgeRect, cornerRadius: badgeSize.height / 2)
        UIColor(white: 0, alpha: 0.55).setFill()
        bg.fill()
        string.draw(
            at: CGPoint(x: badgeRect.midX - textSize.width / 2, y: badgeRect.midY - textSize.height / 2),
            withAttributes: attrs
        )
    }

    /// 이미지를 영역 안에 비율 유지로 가운데 정렬해 넣을 사각형을 계산합니다.
    private static func aspectFitRect(imageSize: CGSize, in area: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, area.width > 0, area.height > 0 else { return area }
        let scale = min(area.width / imageSize.width, area.height / imageSize.height)
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        return CGRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h)
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
