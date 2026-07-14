import Foundation
import CoreGraphics

/// 이미지 안에서 슬라이드 영역을 나타내는 사각형.
/// 모든 좌표는 0...1 로 정규화되어 있고, 원점은 왼쪽 위(UIKit 좌표계)입니다.
struct Quad: Codable, Equatable {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomRight: CGPoint
    var bottomLeft: CGPoint

    /// 이미지 전체 영역
    static let full = Quad(
        topLeft: CGPoint(x: 0, y: 0),
        topRight: CGPoint(x: 1, y: 0),
        bottomRight: CGPoint(x: 1, y: 1),
        bottomLeft: CGPoint(x: 0, y: 1)
    )

    /// 수동 조정 시작용 기본 사각형 (10% 안쪽)
    static let defaultInset = Quad(
        topLeft: CGPoint(x: 0.1, y: 0.1),
        topRight: CGPoint(x: 0.9, y: 0.1),
        bottomRight: CGPoint(x: 0.9, y: 0.9),
        bottomLeft: CGPoint(x: 0.1, y: 0.9)
    )
}

/// 촬영한 장표 한 장
struct Slide: Identifiable, Codable, Equatable {
    let id: UUID
    var createdAt: Date
    /// 원본 사진 파일명 (Images 디렉터리 기준)
    var originalFile: String
    /// 원근 보정된 사진 파일명
    var correctedFile: String
    /// 그리드용 썸네일 파일명
    var thumbFile: String
    /// 보정에 사용된 모서리 좌표 (nil이면 보정 없이 원본 그대로)
    var corners: Quad?
    /// 자동 감지로 보정되었는지 여부
    var autoDetected: Bool
    /// OCR로 인식한 장표 텍스트. nil = 아직 인식 전(기존 데이터), "" = 인식했으나 글자 없음.
    var recognizedText: String?
}

/// 발표(세션) 하나 — 장표들이 순서대로 담긴다
struct Presentation: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var createdAt: Date
    var slides: [Slide]
}
