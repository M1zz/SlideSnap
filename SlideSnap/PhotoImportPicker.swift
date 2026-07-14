import SwiftUI
import PhotosUI

/// 사진 앱에서 기존 강의 사진을 여러 장 골라 발표에 넣기 위한 PHPicker 래퍼.
/// PHPicker는 앱 외부 프로세스에서 동작하므로 사진 접근 권한(Info.plist)이 필요 없습니다.
struct PhotoImportPicker: UIViewControllerRepresentable {

    /// 고른 사진들의 itemProvider 목록을 돌려줍니다(이미지는 호출 측에서 순차 로드).
    let onPick: ([NSItemProvider]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 0            // 0 = 무제한 다중 선택
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: ([NSItemProvider]) -> Void
        init(onPick: @escaping ([NSItemProvider]) -> Void) { self.onPick = onPick }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            onPick(results.map { $0.itemProvider })
        }
    }
}
