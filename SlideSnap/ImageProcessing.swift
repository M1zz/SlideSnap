import UIKit
import Vision
import CoreImage
import os
import QuartzCore

/// Vision 사각형 감지 + Core Image 원근 보정
enum ImageProcessor {

    private static let ciContext = CIContext()

    /// 사진에서 슬라이드(스크린) 영역으로 보이는 사각형을 자동 감지합니다.
    /// 반환되는 Quad는 왼쪽 위 원점, 0...1 정규화 좌표입니다.
    static func detectSlideQuad(in image: UIImage) -> Quad? {
        // 12MP 원본에 감지를 돌리면 매우 느리므로 긴 변 1024px로 줄여서 감지합니다.
        // 정규화 좌표(0...1)라 축소해도 결과 좌표는 그대로입니다.
        let working = image.downsampled(maxDimension: 1024)
        guard let cgImage = working.cgImage else { return nil }

        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.3
        request.maximumAspectRatio = 1.0
        request.minimumSize = 0.15
        request.minimumConfidence = 0.6
        request.maximumObservations = 5
        request.quadratureTolerance = 30

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let observations = request.results, !observations.isEmpty else { return nil }

        // 신뢰도 x 면적이 가장 큰 사각형 선택 (발표장에서 스크린이 보통 가장 큰 사각형)
        func score(_ o: VNRectangleObservation) -> CGFloat {
            CGFloat(o.confidence) * o.boundingBox.width * o.boundingBox.height
        }
        guard let best = observations.max(by: { score($0) < score($1) }) else { return nil }

        // Vision은 왼쪽 아래 원점 → 왼쪽 위 원점으로 변환
        func flip(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: 1 - p.y) }

        return Quad(
            topLeft: flip(best.topLeft),
            topRight: flip(best.topRight),
            bottomRight: flip(best.bottomRight),
            bottomLeft: flip(best.bottomLeft)
        )
    }

    /// 장표 이미지에서 텍스트를 인식합니다(온디바이스 Vision, 한국어+영어).
    /// 인식된 줄들을 개행으로 이어 반환하며, 글자가 없으면 빈 문자열을 반환합니다.
    static func recognizeText(in image: UIImage) -> String {
        // 정확도를 위해 너무 작지 않게, 대신 과도한 해상도는 줄여서 인식합니다.
        guard let cgImage = image.downsampled(maxDimension: 2000).cgImage else { return "" }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["ko-KR", "en-US"]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return ""
        }

        let lines = request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
        return lines.joined(separator: "\n")
    }

    /// 강의 장표를 다시 보기 좋게 가독성을 보정합니다.
    /// 그림자를 밝히고 대비·채도를 살짝 올려 글씨가 또렷해지도록 합니다(스캔 느낌).
    static func enhanceReadability(_ image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        var ci = CIImage(cgImage: cgImage)

        // 1) 그림자/반사로 어두워진 부분을 밝혀 배경을 고르게.
        if let f = CIFilter(name: "CIHighlightShadowAdjust") {
            f.setValue(ci, forKey: kCIInputImageKey)
            f.setValue(0.9, forKey: "inputShadowAmount")
            f.setValue(1.0, forKey: "inputHighlightAmount")
            if let out = f.outputImage { ci = out }
        }
        // 2) 대비·밝기·채도를 살짝 끌어올려 글씨를 또렷하게.
        if let f = CIFilter(name: "CIColorControls") {
            f.setValue(ci, forKey: kCIInputImageKey)
            f.setValue(1.12, forKey: kCIInputContrastKey)
            f.setValue(0.03, forKey: kCIInputBrightnessKey)
            f.setValue(1.08, forKey: kCIInputSaturationKey)
            if let out = f.outputImage { ci = out }
        }

        guard let outCG = ciContext.createCGImage(ci, from: ci.extent) else { return nil }
        return UIImage(cgImage: outCG)
    }

    /// 주어진 모서리를 기준으로 원근 보정을 적용해 반듯한 직사각형 이미지를 만듭니다.
    static func perspectiveCorrected(_ image: UIImage, quad: Quad) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let ciImage = CIImage(cgImage: cgImage)
        let width = ciImage.extent.width
        let height = ciImage.extent.height

        // 정규화(왼쪽 위 원점) → CI 픽셀 좌표(왼쪽 아래 원점)
        func ciVector(_ p: CGPoint) -> CIVector {
            CIVector(x: p.x * width, y: (1 - p.y) * height)
        }

        let output = ciImage.applyingFilter("CIPerspectiveCorrection", parameters: [
            "inputTopLeft": ciVector(quad.topLeft),
            "inputTopRight": ciVector(quad.topRight),
            "inputBottomRight": ciVector(quad.bottomRight),
            "inputBottomLeft": ciVector(quad.bottomLeft)
        ])

        guard let outputCG = ciContext.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: outputCG)
    }
}

extension UIImage {
    /// EXIF 회전 정보를 실제 픽셀에 반영해 orientation이 .up인 이미지로 만듭니다.
    func orientationNormalized() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// 라플라시안 분산으로 선명도를 추정합니다. 값이 낮을수록 흐릿(흔들림/초점 나감)합니다.
    /// 계산할 수 없으면 nil을 반환합니다. 속도를 위해 256px 그레이스케일로 계산합니다.
    func sharpnessVariance() -> Double? {
        guard let cg = downsampled(maxDimension: 256).cgImage else { return nil }
        let w = cg.width, h = cg.height
        guard w >= 3, h >= 3 else { return nil }

        var gray = [UInt8](repeating: 0, count: w * h)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: &gray, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        // 4-이웃 라플라시안의 분산(에지 강도의 분산). 흐린 이미지는 에지가 약해 분산이 낮습니다.
        var sum = 0.0, sumSq = 0.0
        var n = 0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let lap = 4.0 * Double(gray[i])
                    - Double(gray[i - 1]) - Double(gray[i + 1])
                    - Double(gray[i - w]) - Double(gray[i + w])
                sum += lap
                sumSq += lap * lap
                n += 1
            }
        }
        guard n > 0 else { return nil }
        let mean = sum / Double(n)
        return max(0, sumSq / Double(n) - mean * mean)
    }

    /// 흔들리거나 초점이 나가 흐릿한지 여부. 선명도가 threshold 미만이면 흐릿하다고 봅니다.
    /// 계산할 수 없으면(안전) false를 반환해 걸러내지 않습니다.
    /// - Note: threshold는 콘텐츠·기기에 따라 달라 실기기 튜닝이 필요합니다(기본값은 보수적).
    func isBlurry(threshold: Double = 90) -> Bool {
        guard let variance = sharpnessVariance() else { return false }
        return variance < threshold
    }

    /// 긴 변이 maxDimension을 넘지 않도록 축소한 이미지를 반환합니다.
    func downsampled(maxDimension: CGFloat) -> UIImage {
        let largest = max(size.width, size.height)
        guard largest > maxDimension, largest > 0 else { return self }
        let ratio = maxDimension / largest
        let newSize = CGSize(width: size.width * ratio, height: size.height * ratio)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

/// 촬영된 사진을 감지·보정·저장까지 처리해 Slide로 만들어 주는 팩토리.
/// 백그라운드 스레드에서 호출됩니다.
enum SlideFactory {

    private static let log = Logger(subsystem: "com.leeo.slidesnap", category: "processing")

    /// - Parameter detectedQuad: 촬영 화면에서 실시간으로 잡아 둔 모서리(폴백용).
    ///   보정에 쓰는 모서리는 **촬영된 사진 자체에서** 감지합니다. 그래야 감지와 보정이
    ///   같은 좌표계라 결과 비율이 정확합니다. 실시간 모서리는 프리뷰 프레임 좌표계라
    ///   정지 사진에 그대로 적용하면 비율이 찌그러질 수 있어(예: 1:1), 감지 실패 시에만 씁니다.
    static func makeSlide(from image: UIImage, in directory: URL, detectedQuad: Quad? = nil) -> Slide? {
        let t0 = CACurrentMediaTime()
        let normalized = image.orientationNormalized()

        let stillQuad = ImageProcessor.detectSlideQuad(in: normalized)
        let quad = stillQuad ?? validQuad(detectedQuad)
        let usedLiveQuad = stillQuad == nil && quad != nil
        let tDetect = CACurrentMediaTime()

        let corrected: UIImage
        if let quad, let result = ImageProcessor.perspectiveCorrected(normalized, quad: quad) {
            corrected = result
        } else {
            corrected = normalized
        }
        let tCorrect = CACurrentMediaTime()

        let recognizedText = ImageProcessor.recognizeText(in: corrected)

        let id = UUID()
        let slide = Slide(
            id: id,
            createdAt: Date(),
            originalFile: "\(id.uuidString)-orig.jpg",
            correctedFile: "\(id.uuidString)-corr.jpg",
            thumbFile: "\(id.uuidString)-thumb.jpg",
            corners: quad,
            autoDetected: quad != nil,
            recognizedText: recognizedText
        )

        guard
            write(normalized, quality: 0.85, to: directory.appendingPathComponent(slide.originalFile)),
            write(corrected, quality: 0.9, to: directory.appendingPathComponent(slide.correctedFile)),
            write(corrected.downsampled(maxDimension: 600), quality: 0.7, to: directory.appendingPathComponent(slide.thumbFile))
        else { return nil }

        let tEnd = CACurrentMediaTime()
        log.info("makeSlide total \(tEnd - t0, format: .fixed(precision: 2))s (detect \(tDetect - t0, format: .fixed(precision: 2))s live=\(usedLiveQuad), correct \(tCorrect - tDetect, format: .fixed(precision: 2))s, write \(tEnd - tCorrect, format: .fixed(precision: 2))s)")
        return slide
    }

    /// 모서리를 새로 지정해 보정본을 다시 만듭니다. quad가 nil이면 원본 그대로 사용합니다.
    static func reprocess(slide: Slide, quad: Quad?, in directory: URL) -> Slide? {
        let originalURL = directory.appendingPathComponent(slide.originalFile)
        guard let original = UIImage(contentsOfFile: originalURL.path) else { return nil }

        var updated = slide
        let corrected: UIImage
        if let quad, let result = ImageProcessor.perspectiveCorrected(original, quad: quad) {
            corrected = result
            updated.corners = quad
        } else {
            corrected = original
            updated.corners = nil
        }
        updated.autoDetected = false
        updated.recognizedText = ImageProcessor.recognizeText(in: corrected)

        guard write(corrected, quality: 0.9, to: directory.appendingPathComponent(updated.correctedFile)) else {
            return nil
        }

        // 가독성 보정이 켜져 있던 장표는 새 보정본을 기준으로 보정본·썸네일을 다시 만든다.
        if slide.enhanced == true, let enhanced = ImageProcessor.enhanceReadability(corrected) {
            let enhancedName = updated.enhancedFile ?? "\(updated.id.uuidString)-enh.jpg"
            guard
                write(enhanced, quality: 0.9, to: directory.appendingPathComponent(enhancedName)),
                write(enhanced.downsampled(maxDimension: 600), quality: 0.7, to: directory.appendingPathComponent(updated.thumbFile))
            else { return nil }
            updated.enhanced = true
            updated.enhancedFile = enhancedName
        } else {
            guard write(corrected.downsampled(maxDimension: 600), quality: 0.7, to: directory.appendingPathComponent(updated.thumbFile)) else {
                return nil
            }
        }

        return updated
    }

    /// 가독성 보정을 켜거나 끕니다.
    /// - 켜면: 원근 보정본에서 보정본(enhancedFile)을 만들어 저장하고, 썸네일도 보정본 기준으로 갱신합니다.
    /// - 끄면: 썸네일을 원근 보정본 기준으로 되돌립니다(보정본 파일은 남겨 빠른 재적용에 씁니다).
    static func setEnhancement(_ enabled: Bool, slide: Slide, in directory: URL) -> Slide? {
        let correctedURL = directory.appendingPathComponent(slide.correctedFile)
        guard let corrected = UIImage(contentsOfFile: correctedURL.path) else { return nil }

        var updated = slide
        if enabled {
            guard let enhanced = ImageProcessor.enhanceReadability(corrected) else { return nil }
            let enhancedName = slide.enhancedFile ?? "\(slide.id.uuidString)-enh.jpg"
            guard
                write(enhanced, quality: 0.9, to: directory.appendingPathComponent(enhancedName)),
                write(enhanced.downsampled(maxDimension: 600), quality: 0.7, to: directory.appendingPathComponent(slide.thumbFile))
            else { return nil }
            updated.enhanced = true
            updated.enhancedFile = enhancedName
        } else {
            guard write(corrected.downsampled(maxDimension: 600), quality: 0.7, to: directory.appendingPathComponent(slide.thumbFile)) else {
                return nil
            }
            updated.enhanced = false
        }
        return updated
    }

    /// 실시간 모서리가 보정에 쓸 만한지 검사합니다.
    /// nil이거나, 좌표가 범위를 벗어나거나, 감싸는 면적이 너무 작으면(≈찌그러짐) 무시합니다.
    private static func validQuad(_ quad: Quad?) -> Quad? {
        guard let quad else { return nil }
        let points = [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft]
        for p in points where p.x < -0.05 || p.x > 1.05 || p.y < -0.05 || p.y > 1.05 {
            return nil
        }
        // 신발끈 공식으로 다각형 면적 계산 (정규화 좌표 기준)
        var area: CGFloat = 0
        for i in 0..<points.count {
            let a = points[i], b = points[(i + 1) % points.count]
            area += a.x * b.y - b.x * a.y
        }
        area = abs(area) / 2
        return area >= 0.05 ? quad : nil
    }

    private static func write(_ image: UIImage, quality: CGFloat, to url: URL) -> Bool {
        guard let data = image.jpegData(compressionQuality: quality) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
