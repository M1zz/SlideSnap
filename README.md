# 장표스냅 (SlideSnap)

발표를 들으면서 장표(슬라이드)를 빠르게 찍고, 발표별로 정리하는 iOS 앱입니다.
비스듬하게 찍힌 사진도 슬라이드 영역을 자동으로 감지해 반듯한 네모로 펴 주고,
주변 배경은 잘라냅니다.

## 주요 기능

- **발표별 정리** — 발표(세션)를 만들고 그 안에 장표를 순서대로 쌓습니다.
- **빠른 연속 촬영** — 전용 카메라 화면에서 셔터만 계속 누르면 됩니다. 촬영 즉시 백그라운드에서 보정됩니다.
- **자동 원근 보정** — Vision 프레임워크(`VNDetectRectanglesRequest`)로 슬라이드 사각형을 감지하고, Core Image(`CIPerspectiveCorrection`)로 반듯하게 폅니다. 원본은 항상 함께 보관됩니다.
- **수동 모서리 조정** — 자동 감지가 어긋났을 때 네 모서리를 드래그해서 다시 보정할 수 있습니다. ("자동 감지" 재실행, "전체 영역" 선택도 가능)
- **PDF 내보내기** — 발표 하나를 장표 순서대로 묶은 PDF로 만들어 공유(에어드랍, 메신저 등)할 수 있습니다.

## 요구 사항

- Xcode 16 이상
- iOS 17.0 이상
- **실제 기기 필요** — 시뮬레이터에는 카메라가 없으므로 촬영 기능은 실기기에서 테스트하세요.

## 빌드 방법

1. `SlideSnap.xcodeproj`를 Xcode로 엽니다.
2. 프로젝트 설정 → **Signing & Capabilities**에서 본인의 **Team**을 선택합니다.
3. 필요하면 **Bundle Identifier**(`com.leeo.slidesnap`)를 본인 계정에 맞게 바꿉니다.
4. iPhone을 연결하고 Run(⌘R) 합니다.
5. 무료 Apple ID로 서명한 경우, 기기에서 설정 → 일반 → VPN 및 기기 관리에서 개발자 앱을 신뢰해 주세요.

## 사용 방법

1. 첫 화면에서 **+** 버튼으로 발표를 만듭니다 (기본 제목: "7월 14일 발표" 형태).
2. 발표를 열고 **카메라 버튼**을 눌러 촬영 화면으로 들어갑니다.
3. 장표가 바뀔 때마다 셔터를 누릅니다. 왼쪽 아래 썸네일과 숫자로 촬영 수를 확인할 수 있습니다.
4. **완료**를 누르면 그리드에서 보정된 장표들을 볼 수 있습니다.
5. 장표를 탭하면 상세 화면 → **⋯ 메뉴 → 모서리 조정**에서 보정 영역을 직접 고칠 수 있습니다.
6. 발표 화면 오른쪽 위 **공유 버튼**으로 PDF를 내보냅니다.

## 구조

| 파일 | 역할 |
|---|---|
| `Models.swift` | `Presentation`, `Slide`, `Quad` 데이터 모델 |
| `Store.swift` | JSON + 이미지 파일 영속화, 앱 상태 관리 |
| `ImageProcessing.swift` | Vision 사각형 감지, 원근 보정, 슬라이드 생성 파이프라인 |
| `CameraController.swift` | AVFoundation 캡처 세션 |
| `CameraCaptureView.swift` | 전체 화면 연속 촬영 UI |
| `PresentationListView.swift` | 발표 목록 |
| `PresentationDetailView.swift` | 장표 그리드, PDF 내보내기 |
| `SlideDetailView.swift` | 장표 상세 (보정본/원본, 공유, 삭제) |
| `CornerAdjustView.swift` | 모서리 드래그 수동 보정 |
| `PDFExporter.swift` | PDF 생성 |

## 참고

- 사진은 앱 내부(Documents/Images)에만 저장됩니다. 사진 앱에는 저장하지 않습니다.
- 앱 아이콘은 비어 있습니다. `Assets.xcassets/AppIcon.appiconset`에 1024x1024 이미지를 넣으면 됩니다.
