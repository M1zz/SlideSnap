//
//  PPTXExporter.swift
//  SlideSnap
//
//  장표 사진들을 PowerPoint(.pptx) 파일로 내보낸다. 장표마다 16:9 슬라이드 1장,
//  사진은 비율을 유지해 가운데 맞춤하고, 메모는 발표자 노트로 넣는다.
//  Foundation + ImageIO 만 사용한다(UIKit 없이 macOS 에서도 컴파일된다).
//

import Foundation
import ImageIO

enum PPTXExporter {
    /// 슬라이드 한 장의 입력. 이미지는 JPEG 또는 PNG 파일.
    struct SlideInput {
        let imageURL: URL
        let notes: String?
    }

    enum ExportError: LocalizedError {
        /// JPEG·PNG 가 아니거나 크기를 읽을 수 없는 이미지.
        case unsupportedImage(URL)

        var errorDescription: String? {
            switch self {
            case .unsupportedImage(let url): return "지원하지 않는 이미지입니다: \(url.lastPathComponent)"
            }
        }
    }

    // MARK: - 상수

    /// 16:9 슬라이드 크기 (EMU).
    private static let slideWidth = 12_192_000
    private static let slideHeight = 6_858_000
    /// 노트 페이지 크기 (세로 A4 에 가까운 기본값, EMU).
    private static let notesWidth = 6_858_000
    private static let notesHeight = 9_144_000

    private static let nsA = "http://schemas.openxmlformats.org/drawingml/2006/main"
    private static let nsR = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private static let nsP = "http://schemas.openxmlformats.org/presentationml/2006/main"
    private static let nsRel = "http://schemas.openxmlformats.org/package/2006/relationships"
    private static let relBase = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private static let xmlDecl = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
    /// p:/a:/r: 네임스페이스 선언 묶음.
    private static var pNamespaces: String { "xmlns:a=\"\(nsA)\" xmlns:r=\"\(nsR)\" xmlns:p=\"\(nsP)\"" }

    // MARK: - 공개 API

    /// slides 를 슬라이드로 담은 .pptx 를 outputURL 에 쓴다.
    static func makePPTX(title: String, slides: [SlideInput], outputURL: URL) throws {
        var zip = ZipWriter()
        var mediaExtensions = Set<String>()
        var slideParts: [(slide: String, rels: String, notes: String?, notesRels: String?)] = []
        var mediaFiles: [(path: String, data: Data)] = []

        for (i, input) in slides.enumerated() {
            let n = i + 1
            let data = try Data(contentsOf: input.imageURL)
            guard let ext = imageExtension(of: data),
                  let size = displayPixelSize(of: data) else {
                throw ExportError.unsupportedImage(input.imageURL)
            }
            mediaExtensions.insert(ext)
            let mediaName = "image\(n).\(ext)"
            mediaFiles.append(("ppt/media/\(mediaName)", data))

            let notesText = input.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasNotes = !(notesText ?? "").isEmpty

            slideParts.append((
                slide: slideXML(pictureName: mediaName, imageSize: size),
                rels: slideRelsXML(mediaName: mediaName, notesIndex: hasNotes ? n : nil),
                notes: hasNotes ? notesSlideXML(text: notesText ?? "") : nil,
                notesRels: hasNotes ? notesSlideRelsXML(slideIndex: n) : nil
            ))
        }

        let notesIndices = slideParts.indices.filter { slideParts[$0].notes != nil }.map { $0 + 1 }

        // [Content_Types].xml 는 관례상 맨 앞에 둔다.
        zip.addXML("[Content_Types].xml", contentTypesXML(slideCount: slides.count,
                                                           notesIndices: notesIndices,
                                                           mediaExtensions: mediaExtensions))
        zip.addXML("_rels/.rels", rootRelsXML)
        zip.addXML("docProps/core.xml", coreXML(title: title))
        zip.addXML("docProps/app.xml", appXML(slideCount: slides.count))
        zip.addXML("ppt/presentation.xml", presentationXML(slideCount: slides.count))
        zip.addXML("ppt/_rels/presentation.xml.rels", presentationRelsXML(slideCount: slides.count))
        zip.addXML("ppt/presProps.xml", presPropsXML)
        zip.addXML("ppt/viewProps.xml", viewPropsXML)
        zip.addXML("ppt/tableStyles.xml", tableStylesXML)
        zip.addXML("ppt/theme/theme1.xml", themeXML(name: "Office Theme"))
        zip.addXML("ppt/theme/theme2.xml", themeXML(name: "Notes Theme"))
        zip.addXML("ppt/slideMasters/slideMaster1.xml", slideMasterXML)
        zip.addXML("ppt/slideMasters/_rels/slideMaster1.xml.rels", slideMasterRelsXML)
        zip.addXML("ppt/slideLayouts/slideLayout1.xml", slideLayoutXML)
        zip.addXML("ppt/slideLayouts/_rels/slideLayout1.xml.rels", slideLayoutRelsXML)
        zip.addXML("ppt/notesMasters/notesMaster1.xml", notesMasterXML)
        zip.addXML("ppt/notesMasters/_rels/notesMaster1.xml.rels", notesMasterRelsXML)

        for (i, part) in slideParts.enumerated() {
            let n = i + 1
            zip.addXML("ppt/slides/slide\(n).xml", part.slide)
            zip.addXML("ppt/slides/_rels/slide\(n).xml.rels", part.rels)
            if let notes = part.notes, let notesRels = part.notesRels {
                zip.addXML("ppt/notesSlides/notesSlide\(n).xml", notes)
                zip.addXML("ppt/notesSlides/_rels/notesSlide\(n).xml.rels", notesRels)
            }
        }
        for media in mediaFiles {
            zip.addFile(path: media.path, data: media.data)
        }

        try zip.write(to: outputURL)
    }

    // MARK: - 이미지 정보

    /// 파일 시그니처로 형식을 판별해 ppt/media 에 쓸 확장자를 돌려준다.
    private static func imageExtension(of data: Data) -> String? {
        let bytes = [UInt8](data.prefix(8))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpeg" }
        return nil
    }

    /// 화면에 보이는 방향 기준 픽셀 크기. EXIF 방향이 90°/270° 회전(5~8)이면 가로·세로를 바꾼다.
    private static func displayPixelSize(of data: Data) -> (width: Double, height: Double)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let w = (props[kCGImagePropertyPixelWidth as String] as? NSNumber)?.doubleValue,
              let h = (props[kCGImagePropertyPixelHeight as String] as? NSNumber)?.doubleValue,
              w > 0, h > 0 else { return nil }
        let orientation = (props[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation) ? (h, w) : (w, h)
    }

    /// 이미지를 비율 유지로 슬라이드 가운데에 맞춘 위치·크기 (EMU).
    private static func fitRect(_ size: (width: Double, height: Double)) -> (x: Int, y: Int, cx: Int, cy: Int) {
        let scale = min(Double(slideWidth) / size.width, Double(slideHeight) / size.height)
        let cx = min(Int((size.width * scale).rounded()), slideWidth)
        let cy = min(Int((size.height * scale).rounded()), slideHeight)
        return ((slideWidth - cx) / 2, (slideHeight - cy) / 2, cx, cy)
    }

    // MARK: - XML 도우미

    /// XML 텍스트 이스케이프. XML 1.0 에서 허용되지 않는 제어문자는 뺀다.
    private static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            case "\t", "\n", "\r": out.unicodeScalars.append(scalar)
            default:
                let v = scalar.value
                if v < 0x20 || v == 0xFFFE || v == 0xFFFF { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// 빈 도형 트리의 필수 머리(그룹 속성).
    private static let spTreeHeader = """
    <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>\
    <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>
    """

    /// 검정 단색 배경.
    private static let blackBackground = """
    <p:bg><p:bgPr><a:solidFill><a:srgbClr val="000000"/></a:solidFill><a:effectLst/></p:bgPr></p:bg>
    """

    private static let defaultClrMap = """
    <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" \
    accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>
    """

    private static func relationships(_ items: [(id: String, type: String, target: String)]) -> String {
        let body = items.map {
            "<Relationship Id=\"\($0.id)\" Type=\"\(relBase)/\($0.type)\" Target=\"\($0.target)\"/>"
        }.joined()
        return xmlDecl + "<Relationships xmlns=\"\(nsRel)\">\(body)</Relationships>"
    }

    // MARK: - 패키지 수준 파트

    private static func contentTypesXML(slideCount: Int, notesIndices: [Int], mediaExtensions: Set<String>) -> String {
        let pml = "application/vnd.openxmlformats-officedocument.presentationml"
        var overrides: [(String, String)] = [
            ("/ppt/presentation.xml", "\(pml).presentation.main+xml"),
            ("/ppt/presProps.xml", "\(pml).presProps+xml"),
            ("/ppt/viewProps.xml", "\(pml).viewProps+xml"),
            ("/ppt/tableStyles.xml", "\(pml).tableStyles+xml"),
            ("/ppt/theme/theme1.xml", "application/vnd.openxmlformats-officedocument.theme+xml"),
            ("/ppt/theme/theme2.xml", "application/vnd.openxmlformats-officedocument.theme+xml"),
            ("/ppt/slideMasters/slideMaster1.xml", "\(pml).slideMaster+xml"),
            ("/ppt/slideLayouts/slideLayout1.xml", "\(pml).slideLayout+xml"),
            ("/ppt/notesMasters/notesMaster1.xml", "\(pml).notesMaster+xml"),
            ("/docProps/core.xml", "application/vnd.openxmlformats-package.core-properties+xml"),
            ("/docProps/app.xml", "application/vnd.openxmlformats-officedocument.extended-properties+xml"),
        ]
        for n in stride(from: 1, through: slideCount, by: 1) {
            overrides.append(("/ppt/slides/slide\(n).xml", "\(pml).slide+xml"))
        }
        for n in notesIndices {
            overrides.append(("/ppt/notesSlides/notesSlide\(n).xml", "\(pml).notesSlide+xml"))
        }

        var defaults = [
            "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>",
            "<Default Extension=\"xml\" ContentType=\"application/xml\"/>",
        ]
        let mediaTypes = ["jpeg": "image/jpeg", "png": "image/png"]
        for ext in mediaExtensions.sorted() {
            if let type = mediaTypes[ext] {
                defaults.append("<Default Extension=\"\(ext)\" ContentType=\"\(type)\"/>")
            }
        }

        let overrideXML = overrides.map { "<Override PartName=\"\($0.0)\" ContentType=\"\($0.1)\"/>" }.joined()
        return xmlDecl
            + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
            + defaults.joined() + overrideXML + "</Types>"
    }

    private static var rootRelsXML: String {
        xmlDecl + """
        <Relationships xmlns="\(nsRel)">\
        <Relationship Id="rId1" Type="\(relBase)/officeDocument" Target="ppt/presentation.xml"/>\
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>\
        <Relationship Id="rId3" Type="\(relBase)/extended-properties" Target="docProps/app.xml"/>\
        </Relationships>
        """
    }

    private static func coreXML(title: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let now = formatter.string(from: Date())
        return xmlDecl + """
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
        xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" \
        xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\
        <dc:title>\(escape(title))</dc:title>\
        <dc:creator>SlideSnap</dc:creator>\
        <cp:lastModifiedBy>SlideSnap</cp:lastModifiedBy>\
        <cp:revision>1</cp:revision>\
        <dcterms:created xsi:type="dcterms:W3CDTF">\(now)</dcterms:created>\
        <dcterms:modified xsi:type="dcterms:W3CDTF">\(now)</dcterms:modified>\
        </cp:coreProperties>
        """
    }

    private static func appXML(slideCount: Int) -> String {
        xmlDecl + """
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" \
        xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">\
        <Application>SlideSnap</Application>\
        <PresentationFormat>Widescreen</PresentationFormat>\
        <Slides>\(slideCount)</Slides>\
        </Properties>
        """
    }

    // MARK: - 프레젠테이션

    /// presentation.xml.rels 의 고정 관계 수. 슬라이드는 rId(fixedRelCount+1)부터.
    private static let fixedRelCount = 6

    private static func presentationXML(slideCount: Int) -> String {
        var slideIds = ""
        if slideCount > 0 {
            slideIds = "<p:sldIdLst>" + (0..<slideCount).map {
                "<p:sldId id=\"\(256 + $0)\" r:id=\"rId\(fixedRelCount + 1 + $0)\"/>"
            }.joined() + "</p:sldIdLst>"
        }
        return xmlDecl + """
        <p:presentation \(pNamespaces) saveSubsetFonts="1">\
        <p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>\
        <p:notesMasterIdLst><p:notesMasterId r:id="rId2"/></p:notesMasterIdLst>\
        \(slideIds)\
        <p:sldSz cx="\(slideWidth)" cy="\(slideHeight)"/>\
        <p:notesSz cx="\(notesWidth)" cy="\(notesHeight)"/>\
        <p:defaultTextStyle><a:defPPr><a:defRPr lang="ko-KR"/></a:defPPr>\
        <a:lvl1pPr marL="0" algn="l" defTabSz="914400" rtl="0" eaLnBrk="1" latinLnBrk="0" hangingPunct="1">\
        <a:defRPr sz="1800" kern="1200"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill>\
        <a:latin typeface="+mn-lt"/><a:ea typeface="+mn-ea"/><a:cs typeface="+mn-cs"/></a:defRPr></a:lvl1pPr>\
        </p:defaultTextStyle>\
        </p:presentation>
        """
    }

    private static func presentationRelsXML(slideCount: Int) -> String {
        var items: [(id: String, type: String, target: String)] = [
            ("rId1", "slideMaster", "slideMasters/slideMaster1.xml"),
            ("rId2", "notesMaster", "notesMasters/notesMaster1.xml"),
            ("rId3", "theme", "theme/theme1.xml"),
            ("rId4", "presProps", "presProps.xml"),
            ("rId5", "viewProps", "viewProps.xml"),
            ("rId6", "tableStyles", "tableStyles.xml"),
        ]
        for i in 0..<slideCount {
            items.append(("rId\(fixedRelCount + 1 + i)", "slide", "slides/slide\(i + 1).xml"))
        }
        return relationships(items)
    }

    private static var presPropsXML: String {
        xmlDecl + "<p:presentationPr \(pNamespaces)/>"
    }

    private static var viewPropsXML: String {
        xmlDecl + """
        <p:viewPr \(pNamespaces)>\
        <p:normalViewPr><p:restoredLeft sz="15620"/><p:restoredTop sz="94660"/></p:normalViewPr>\
        <p:gridSpacing cx="76200" cy="76200"/>\
        </p:viewPr>
        """
    }

    private static var tableStylesXML: String {
        xmlDecl + "<a:tblStyleLst xmlns:a=\"\(nsA)\" def=\"{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}\"/>"
    }

    // MARK: - 마스터·레이아웃

    private static var slideMasterXML: String {
        xmlDecl + """
        <p:sldMaster \(pNamespaces)>\
        <p:cSld>\(blackBackground)<p:spTree>\(spTreeHeader)</p:spTree></p:cSld>\
        \(defaultClrMap)\
        <p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst>\
        <p:txStyles>\
        <p:titleStyle><a:lvl1pPr><a:defRPr sz="4400"/></a:lvl1pPr></p:titleStyle>\
        <p:bodyStyle><a:lvl1pPr><a:defRPr sz="2800"/></a:lvl1pPr></p:bodyStyle>\
        <p:otherStyle><a:lvl1pPr><a:defRPr sz="1800"/></a:lvl1pPr></p:otherStyle>\
        </p:txStyles>\
        </p:sldMaster>
        """
    }

    private static var slideMasterRelsXML: String {
        relationships([
            ("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml"),
            ("rId2", "theme", "../theme/theme1.xml"),
        ])
    }

    private static var slideLayoutXML: String {
        xmlDecl + """
        <p:sldLayout \(pNamespaces) type="blank" preserve="1">\
        <p:cSld name="Blank"><p:spTree>\(spTreeHeader)</p:spTree></p:cSld>\
        <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>\
        </p:sldLayout>
        """
    }

    private static var slideLayoutRelsXML: String {
        relationships([("rId1", "slideMaster", "../slideMasters/slideMaster1.xml")])
    }

    // MARK: - 슬라이드

    private static func slideXML(pictureName: String, imageSize: (width: Double, height: Double)) -> String {
        let r = fitRect(imageSize)
        return xmlDecl + """
        <p:sld \(pNamespaces)>\
        <p:cSld>\(blackBackground)<p:spTree>\(spTreeHeader)\
        <p:pic>\
        <p:nvPicPr><p:cNvPr id="2" name="\(escape(pictureName))"/>\
        <p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>\
        <p:blipFill><a:blip r:embed="rId2"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>\
        <p:spPr><a:xfrm><a:off x="\(r.x)" y="\(r.y)"/><a:ext cx="\(r.cx)" cy="\(r.cy)"/></a:xfrm>\
        <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>\
        </p:pic>\
        </p:spTree></p:cSld>\
        <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>\
        </p:sld>
        """
    }

    private static func slideRelsXML(mediaName: String, notesIndex: Int?) -> String {
        var items: [(id: String, type: String, target: String)] = [
            ("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml"),
            ("rId2", "image", "../media/\(mediaName)"),
        ]
        if let n = notesIndex {
            items.append(("rId3", "notesSlide", "../notesSlides/notesSlide\(n).xml"))
        }
        return relationships(items)
    }

    // MARK: - 발표자 노트

    /// 노트 페이지의 슬라이드 그림 영역·본문 영역 (EMU).
    private static let notesImageFrame = (x: 381_000, y: 685_800, cx: 6_096_000, cy: 3_429_000)
    private static let notesBodyFrame = (x: 685_800, y: 4_343_400, cx: 5_486_400, cy: 4_114_800)

    private static var notesMasterXML: String {
        let img = notesImageFrame
        let body = notesBodyFrame
        return xmlDecl + """
        <p:notesMaster \(pNamespaces)>\
        <p:cSld><p:bg><p:bgRef idx="1001"><a:schemeClr val="bg1"/></p:bgRef></p:bg><p:spTree>\(spTreeHeader)\
        <p:sp><p:nvSpPr><p:cNvPr id="2" name="Slide Image Placeholder 1"/>\
        <p:cNvSpPr><a:spLocks noGrp="1" noRot="1" noChangeAspect="1"/></p:cNvSpPr>\
        <p:nvPr><p:ph type="sldImg" idx="2"/></p:nvPr></p:nvSpPr>\
        <p:spPr><a:xfrm><a:off x="\(img.x)" y="\(img.y)"/><a:ext cx="\(img.cx)" cy="\(img.cy)"/></a:xfrm>\
        <a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/>\
        <a:ln w="12700"><a:solidFill><a:prstClr val="black"/></a:solidFill></a:ln></p:spPr></p:sp>\
        <p:sp><p:nvSpPr><p:cNvPr id="3" name="Notes Placeholder 2"/>\
        <p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr>\
        <p:nvPr><p:ph type="body" sz="quarter" idx="3"/></p:nvPr></p:nvSpPr>\
        <p:spPr><a:xfrm><a:off x="\(body.x)" y="\(body.y)"/><a:ext cx="\(body.cx)" cy="\(body.cy)"/></a:xfrm>\
        <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>\
        <p:txBody><a:bodyPr vert="horz" lIns="91440" tIns="45720" rIns="91440" bIns="45720" rtlCol="0"/>\
        <a:lstStyle/><a:p><a:pPr lvl="0"/><a:endParaRPr lang="ko-KR"/></a:p></p:txBody></p:sp>\
        </p:spTree></p:cSld>\
        \(defaultClrMap)\
        <p:notesStyle>\
        <a:lvl1pPr marL="0" algn="l" defTabSz="914400" rtl="0" eaLnBrk="1" latinLnBrk="0" hangingPunct="1">\
        <a:defRPr sz="1200" kern="1200"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill>\
        <a:latin typeface="+mn-lt"/><a:ea typeface="+mn-ea"/><a:cs typeface="+mn-cs"/></a:defRPr></a:lvl1pPr>\
        </p:notesStyle>\
        </p:notesMaster>
        """
    }

    private static var notesMasterRelsXML: String {
        relationships([("rId1", "theme", "../theme/theme2.xml")])
    }

    /// 노트 본문. 줄마다 문단(<a:p>) 하나, 빈 줄은 빈 문단.
    private static func notesSlideXML(text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let paragraphs = normalized.components(separatedBy: "\n").map { line -> String in
            line.isEmpty
                ? "<a:p><a:endParaRPr lang=\"ko-KR\" dirty=\"0\"/></a:p>"
                : "<a:p><a:r><a:rPr lang=\"ko-KR\" dirty=\"0\"/><a:t>\(escape(line))</a:t></a:r></a:p>"
        }.joined()
        return xmlDecl + """
        <p:notes \(pNamespaces)>\
        <p:cSld><p:spTree>\(spTreeHeader)\
        <p:sp><p:nvSpPr><p:cNvPr id="2" name="Slide Image Placeholder 1"/>\
        <p:cNvSpPr><a:spLocks noGrp="1" noRot="1" noChangeAspect="1"/></p:cNvSpPr>\
        <p:nvPr><p:ph type="sldImg" idx="2"/></p:nvPr></p:nvSpPr><p:spPr/></p:sp>\
        <p:sp><p:nvSpPr><p:cNvPr id="3" name="Notes Placeholder 2"/>\
        <p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr>\
        <p:nvPr><p:ph type="body" idx="3"/></p:nvPr></p:nvSpPr><p:spPr/>\
        <p:txBody><a:bodyPr/><a:lstStyle/>\(paragraphs)</p:txBody></p:sp>\
        </p:spTree></p:cSld>\
        <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>\
        </p:notes>
        """
    }

    private static func notesSlideRelsXML(slideIndex n: Int) -> String {
        relationships([
            ("rId1", "notesMaster", "../notesMasters/notesMaster1.xml"),
            ("rId2", "slide", "../slides/slide\(n).xml"),
        ])
    }

    // MARK: - 테마

    /// Office 기본값에 가까운 최소 테마. 색·글꼴·서식 체계가 모두 있어야 PowerPoint 가 복구 경고를 띄우지 않는다.
    private static func themeXML(name: String) -> String {
        func solid(_ mods: String) -> String {
            "<a:solidFill><a:schemeClr val=\"phClr\">\(mods)</a:schemeClr></a:solidFill>"
        }
        let line = { (w: Int) in
            "<a:ln w=\"\(w)\" cap=\"flat\" cmpd=\"sng\" algn=\"ctr\">\(solid(""))<a:prstDash val=\"solid\"/><a:miter lim=\"800000\"/></a:ln>"
        }
        return xmlDecl + """
        <a:theme xmlns:a="\(nsA)" name="\(escape(name))"><a:themeElements>\
        <a:clrScheme name="Office">\
        <a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1>\
        <a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1>\
        <a:dk2><a:srgbClr val="44546A"/></a:dk2>\
        <a:lt2><a:srgbClr val="E7E6E6"/></a:lt2>\
        <a:accent1><a:srgbClr val="4472C4"/></a:accent1>\
        <a:accent2><a:srgbClr val="ED7D31"/></a:accent2>\
        <a:accent3><a:srgbClr val="A5A5A5"/></a:accent3>\
        <a:accent4><a:srgbClr val="FFC000"/></a:accent4>\
        <a:accent5><a:srgbClr val="5B9BD5"/></a:accent5>\
        <a:accent6><a:srgbClr val="70AD47"/></a:accent6>\
        <a:hlink><a:srgbClr val="0563C1"/></a:hlink>\
        <a:folHlink><a:srgbClr val="954F72"/></a:folHlink>\
        </a:clrScheme>\
        <a:fontScheme name="Office">\
        <a:majorFont><a:latin typeface="Calibri Light"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont>\
        <a:minorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont>\
        </a:fontScheme>\
        <a:fmtScheme name="Office">\
        <a:fillStyleLst>\(solid(""))\(solid("<a:tint val=\"50000\"/>"))\(solid("<a:shade val=\"80000\"/>"))</a:fillStyleLst>\
        <a:lnStyleLst>\(line(6350))\(line(12700))\(line(19050))</a:lnStyleLst>\
        <a:effectStyleLst>\
        <a:effectStyle><a:effectLst/></a:effectStyle>\
        <a:effectStyle><a:effectLst/></a:effectStyle>\
        <a:effectStyle><a:effectLst/></a:effectStyle>\
        </a:effectStyleLst>\
        <a:bgFillStyleLst>\(solid(""))\(solid("<a:tint val=\"95000\"/>"))\(solid("<a:shade val=\"90000\"/>"))</a:bgFillStyleLst>\
        </a:fmtScheme>\
        </a:themeElements><a:objectDefaults/><a:extraClrSchemeLst/></a:theme>
        """
    }
}

// MARK: - ZipWriter 편의

private extension ZipWriter {
    mutating func addXML(_ path: String, _ xml: String) {
        addFile(path: path, data: Data(xml.utf8))
    }
}
