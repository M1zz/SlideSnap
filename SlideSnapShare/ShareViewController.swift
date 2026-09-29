//
//  ShareViewController.swift
//  SlideSnapShare
//
//  사진 앱에서 여러 장을 골라 "공유 → 장표스냅"을 누르면 뜨는 화면.
//  사진을 App Group 수신함에 옮겨 두고 제목·순서·보정 여부를 정한 뒤 앱을 연다.
//  무거운 처리(모서리 감지·원근 보정·글자 인식)는 메모리 제한이 빡빡한 익스텐션 대신 앱이 맡는다.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {

    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.onCancel = { [weak self] in self?.cancel() }
        model.onFinish = { [weak self] in self?.finish() }
        model.openApp = { [weak self] completion in self?.openHostApp(completion: completion) }

        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)

        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
        Task { await model.load(providers) }
    }

    private func cancel() {
        model.discard()
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// 익스텐션은 UIApplication.shared를 못 쓰므로 응답자 체인에서 앱 객체를 찾아 연다.
    /// 실패하면(시스템이 막으면) false — 이때는 사용자가 직접 앱을 열면 수신함에서 가져간다.
    private func openHostApp(completion: @escaping (Bool) -> Void) {
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(ShareInbox.openURL, options: [:], completionHandler: completion)
                return
            }
            responder = current.next
        }
        completion(false)
    }
}
