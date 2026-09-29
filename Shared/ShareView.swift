//
//  ShareView.swift
//  SlideSnap (공유 익스텐션 화면 · 앱의 DEBUG 데모 모드에서도 같은 화면을 띄운다)
//
//  사진을 수신함으로 옮기고 제목·순서·보정 여부를 고르는 화면과 그 상태.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - 모델

@MainActor
final class ShareModel: ObservableObject, Identifiable {

    enum Phase: Equatable {
        case loading(done: Int, total: Int)
        case ready
        case saved       // 수신함에 넣었지만 앱을 자동으로 열지 못함
        case failed(String)
    }

    enum Order: String, CaseIterable, Identifiable {
        case captured
        case selected
        var id: String { rawValue }
        var label: LocalizedStringKey {
            switch self {
            case .captured: return "촬영한 시간순"
            case .selected: return "고른 순서"
            }
        }
    }

    struct Item: Identifiable {
        let id = UUID()
        let file: String
        let capturedAt: Date?
        let thumbnail: UIImage?
    }

    @Published var phase: Phase = .loading(done: 0, total: 0)
    @Published var items: [Item] = []
    @Published var title = ""
    @Published var order: Order = .captured
    @Published var enhance = false
    @Published var isSaving = false

    var onCancel: () -> Void = {}
    var onFinish: () -> Void = {}
    var openApp: (@escaping (Bool) -> Void) -> Void = { $0(false) }

    private let batchID = UUID()
    private var batchURL: URL?

    /// 현재 정렬 기준으로 늘어선 사진들.
    var orderedItems: [Item] {
        switch order {
        case .selected:
            return items
        case .captured:
            // 촬영 시각이 없는 사진은 고른 순서를 지키며 맨 뒤로.
            return items.enumerated().sorted { a, b in
                switch (a.element.capturedAt, b.element.capturedAt) {
                case let (x?, y?): return x == y ? a.offset < b.offset : x < y
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return a.offset < b.offset
                }
            }.map(\.element)
        }
    }

    /// 사진들을 한 장씩 수신함 폴더로 복사한다(디코딩하지 않아 메모리를 거의 안 쓴다).
    func load(_ providers: [NSItemProvider]) async {
        guard !providers.isEmpty else {
            phase = .failed(String(localized: "공유할 수 있는 사진이 없어요."))
            return
        }
        do {
            batchURL = try ShareInbox.makeBatchDirectory(batchID)
        } catch {
            phase = .failed(String(localized: "사진을 담을 공간을 만들지 못했어요."))
            return
        }
        guard let batchURL else { return }

        phase = .loading(done: 0, total: providers.count)
        var loaded: [Item] = []
        for (index, provider) in providers.enumerated() {
            let baseName = String(format: "%04d", index + 1)
            if let file = await Self.copyImage(from: provider, to: batchURL, baseName: baseName) {
                let url = batchURL.appendingPathComponent(file)
                let date = ShareInbox.captureDate(of: url)
                let thumb = await Task.detached(priority: .userInitiated) {
                    Self.thumbnail(of: url, maxPixel: 240)
                }.value
                loaded.append(Item(file: file, capturedAt: date, thumbnail: thumb))
            }
            phase = .loading(done: index + 1, total: providers.count)
        }

        items = loaded
        guard !loaded.isEmpty else {
            phase = .failed(String(localized: "사진을 불러오지 못했어요."))
            return
        }
        title = ShareInbox.defaultTitle(for: loaded.map(\.capturedAt))
        phase = .ready
    }

    func save() {
        guard !isSaving else { return }
        isSaving = true
        let ordered = orderedItems
        let manifest = ShareInbox.Manifest(
            id: batchID,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            files: ordered.map(\.file),
            capturedAt: ordered.map(\.capturedAt),
            enhance: enhance,
            createdAt: Date()
        )
        do {
            try ShareInbox.commit(manifest)
        } catch {
            isSaving = false
            phase = .failed(String(localized: "사진을 넘기지 못했어요. 다시 시도해 주세요."))
            return
        }
        openApp { [weak self] opened in
            Task { @MainActor in
                guard let self else { return }
                if opened {
                    self.onFinish()
                } else {
                    self.isSaving = false
                    self.phase = .saved
                }
            }
        }
    }

    func discard() {
        ShareInbox.discard(batchID)
    }

    // MARK: - 파일 옮기기

    /// 원본 파일(EXIF 포함)을 우선 그대로 복사하고, 파일로 줄 수 없는 경우만 이미지로 받아 JPEG로 쓴다.
    private static func copyImage(from provider: NSItemProvider, to directory: URL, baseName: String) async -> String? {
        if let file = await copyFileRepresentation(from: provider, to: directory, baseName: baseName) {
            return file
        }
        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.image.identifier) { item, _ in
                var data: Data?
                if let url = item as? URL {
                    data = try? Data(contentsOf: url)
                } else if let raw = item as? Data {
                    data = raw
                } else if let image = item as? UIImage {
                    data = image.jpegData(compressionQuality: 0.9)
                }
                guard let data, UIImage(data: data) != nil else {
                    continuation.resume(returning: nil)
                    return
                }
                let name = "\(baseName).jpg"
                let ok = (try? data.write(to: directory.appendingPathComponent(name))) != nil
                continuation.resume(returning: ok ? name : nil)
            }
        }
    }

    private static func copyFileRepresentation(from provider: NSItemProvider, to directory: URL, baseName: String) async -> String? {
        // 가장 구체적인 이미지 형식(heic, jpeg 등)을 고른다.
        guard let typeID = provider.registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: .image) == true
        }) else { return nil }
        return await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeID) { url, _ in
                // 넘겨받은 url은 이 블록이 끝나면 지워지므로 여기서 바로 복사한다.
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }
                let ext = url.pathExtension.isEmpty
                    ? (UTType(typeID)?.preferredFilenameExtension ?? "jpg")
                    : url.pathExtension
                let name = "\(baseName).\(ext.lowercased())"
                let destination = directory.appendingPathComponent(name)
                do {
                    try FileManager.default.copyItem(at: url, to: destination)
                    continuation.resume(returning: name)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    nonisolated private static func thumbnail(of url: URL, maxPixel: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - 화면

struct ShareView: View {

    @ObservedObject var model: ShareModel

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("장표스냅으로 정리")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        if model.phase != .saved {
                            Button("취소") { model.onCancel() }
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if model.phase == .saved {
                            Button("확인") { model.onFinish() }
                        } else {
                            Button("발표 만들기") { model.save() }
                                .fontWeight(.semibold)
                                .disabled(model.phase != .ready || model.isSaving)
                        }
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case let .loading(done, total):
            VStack(spacing: 14) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .progressViewStyle(.circular)
                Group {
                    if total > 0 {
                        Text("사진 불러오는 중 \(done)/\(total)")
                    } else {
                        Text("사진 불러오는 중")
                    }
                }
                .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .ready:
            form

        case .saved:
            ContentUnavailableView {
                Label("사진을 넘겼어요", systemImage: "checkmark.circle.fill")
            } description: {
                Text("장표스냅을 열면 \(model.items.count)장이\n'\(model.title.isEmpty ? String(localized: "새 발표") : model.title)' 발표로 정리돼 있어요.")
            }

        case let .failed(message):
            ContentUnavailableView(
                "가져올 수 없어요",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        }
    }

    private var form: some View {
        Form {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(Array(model.orderedItems.enumerated()), id: \.element.id) { index, item in
                            thumbnail(item, number: index + 1)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            } header: {
                Text("사진 \(model.items.count)장")
            }

            Section("발표 제목") {
                TextField("발표 제목", text: $model.title)
            }

            Section {
                Picker("장표 순서", selection: $model.order.animation()) {
                    ForEach(ShareModel.Order.allCases) { order in
                        Text(order.label).tag(order)
                    }
                }
                Toggle("글자 또렷하게 보정", isOn: $model.enhance)
            } footer: {
                Text("사진마다 장표 모서리를 찾아 반듯하게 펴고, 글자를 인식해 검색할 수 있게 정리해요. 글자 보정은 그림자와 흐린 대비를 걷어 내요.")
            }
        }
    }

    private func thumbnail(_ item: ShareModel.Item, number: Int) -> some View {
        Group {
            if let image = item.thumbnail {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(Color(.secondarySystemBackground))
            }
        }
        .frame(width: 88, height: 66)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .topLeading) {
            Text("\(number)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(4)
        }
    }
}
