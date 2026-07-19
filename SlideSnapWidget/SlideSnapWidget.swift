//
//  SlideSnapWidget.swift
//  SlideSnapWidget
//
//  탭 한 번으로 장표스냅 카메라를 바로 여는 위젯.
//  홈 화면(systemSmall)과 잠금화면(accessory*) 모두 지원한다.
//  어느 위젯이든 slidesnap://camera 딥링크로 앱을 열고, 앱이 카메라를 실행한다.
//

import WidgetKit
import SwiftUI

struct CameraEntry: TimelineEntry {
    let date: Date
}

/// 정적 위젯이라 갱신이 필요 없다. 한 번만 엔트리를 만든다.
struct CameraProvider: TimelineProvider {
    func placeholder(in context: Context) -> CameraEntry {
        CameraEntry(date: Date())
    }
    func getSnapshot(in context: Context, completion: @escaping (CameraEntry) -> Void) {
        completion(CameraEntry(date: Date()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<CameraEntry>) -> Void) {
        completion(Timeline(entries: [CameraEntry(date: Date())], policy: .never))
    }
}

struct SlideSnapCameraWidget: Widget {
    let kind = "SlideSnapCameraWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CameraProvider()) { _ in
            CameraWidgetView()
        }
        .configurationDisplayName("바로 촬영")
        .description("탭하면 장표스냅 카메라가 바로 열려요. 홈 화면과 잠금화면에서 쓸 수 있어요.")
        .supportedFamilies([
            .systemSmall,
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline
        ])
    }
}

struct CameraWidgetView: View {
    @Environment(\.widgetFamily) private var family

    private let cameraURL = URL(string: "slidesnap://camera")

    var body: some View {
        switch family {
        case .accessoryCircular:
            circular
        case .accessoryRectangular:
            rectangular
        case .accessoryInline:
            // 잠금화면 시계 위 한 줄 슬롯: 아이콘 + 짧은 라벨.
            Label("장표 촬영", systemImage: "camera.fill")
                .widgetURL(cameraURL)
        default:
            home
        }
    }

    // MARK: - 잠금화면 (accessory)

    /// 원형 슬롯 — 아이콘만. 시스템이 자동으로 단색·틴트 처리한다.
    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image(systemName: "camera.fill")
                .font(.system(size: 22, weight: .semibold))
        }
        .containerBackground(for: .widget) { Color.clear }
        .widgetURL(cameraURL)
    }

    /// 가로 슬롯 — 아이콘 + 안내 문구.
    private var rectangular: some View {
        HStack(spacing: 8) {
            Image(systemName: "camera.fill")
                .font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text("장표 촬영")
                    .font(.headline)
                Text("탭해서 바로 촬영")
                    .font(.caption2)
            }
            Spacer(minLength: 0)
        }
        .containerBackground(for: .widget) { Color.clear }
        .widgetURL(cameraURL)
    }

    // MARK: - 홈 화면

    private var home: some View {
        VStack(spacing: 8) {
            Image(systemName: "camera.fill")
                .font(.system(size: 34, weight: .semibold))
            Text("장표 촬영")
                .font(.headline)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [Color.accentColor, Color.accentColor.opacity(0.65)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .widgetURL(cameraURL)
    }
}

#Preview(as: .systemSmall) {
    SlideSnapCameraWidget()
} timeline: {
    CameraEntry(date: Date())
}

#Preview(as: .accessoryCircular) {
    SlideSnapCameraWidget()
} timeline: {
    CameraEntry(date: Date())
}

#Preview(as: .accessoryRectangular) {
    SlideSnapCameraWidget()
} timeline: {
    CameraEntry(date: Date())
}
