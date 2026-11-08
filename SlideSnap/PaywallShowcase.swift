//
//  PaywallShowcase.swift
//  SlideSnap
//
//  페이월에서 옆으로 넘겨 보는 기능 그림 (LeeoKit `LeeoShowcase`, 클립키보드와 같은 틀).
//  고른 칸의 기능만 보이고, 들어온 자리의 기능이 첫 장이다.
//
//  스크린샷이 아니라 SwiftUI 로 줄여 그린다 — 언어 · 다크 모드 · 키 색을 따라가고 앱 용량이 늘지 않는다.
//  ⚠️ 그림 속 글자는 기호 · 숫자 · 파일 형식 이름뿐. 문장은 그림 아래 한 줄이 맡는다.
//  ⚠️ 제목은 비교표(`PlanComparisonTable`)의 줄 이름과 같은 말을 쓴다 — 두 곳이 다른 이름을 부르지 않게.
//

import SwiftUI
import LeeoKit

extension ProTier {
    /// 이 칸에서 새로 열리는 것의 그림. `first` 가 이 칸이면 그 장을 맨 앞에 둔다.
    func showcases(first: ProFeature? = nil) -> [LeeoShowcase] {
        var pages: [(ProFeature?, LeeoShowcase)] = switch self {
        case .free: []
        case .plus: [
            (.unlimitedPresentations, LeeoShowcase(id: "presentations", title: String(localized: "발표 무제한"),
                detail: String(localized: "한 학기 강의도 학회 세션도 개수 걱정 없이 묶어요")) { PresentationsArt() }),
            (.enhance, LeeoShowcase(id: "enhance", title: String(localized: "또렷하게 보정"),
                detail: String(localized: "그림자와 흐린 대비를 걷어 글자를 살려요")) { EnhanceArt() }),
            (.pdfLayouts, LeeoShowcase(id: "pdf", title: String(localized: "PDF 두 장 · 네 장씩"),
                detail: String(localized: "한 쪽에 장표를 모아 종이를 아껴 인쇄해요")) { PDFLayoutArt() }),
        ]
        case .pro: [
            (.summary, LeeoShowcase(id: "summary", title: String(localized: "기기 안 요약"),
                detail: String(localized: "발표 내용을 밖으로 보내지 않고 기기 안에서 요약해요")) { SummaryArt() }),
            (.notesExport, LeeoShowcase(id: "export", title: String(localized: "PowerPoint · Markdown 내보내기"),
                detail: String(localized: "장표와 요약 · 메모를 한 파일로 내보내요")) { ExportArt() }),
            (.sync, LeeoShowcase(id: "sync", title: String(localized: "iCloud 동기화"),
                detail: String(localized: "iPhone · iPad · Mac에서 같은 발표를 봐요")) { SyncArt() }),
            (nil, LeeoShowcase(id: "plus", title: String(localized: "Plus의 모든 것"),
                detail: String(localized: "Plus에서 열리는 것을 모두 그대로 써요")) { EverythingInPlusArt() }),
        ]
        }
        if let first, let i = pages.firstIndex(where: { $0.0 == first }) {
            pages.insert(pages.remove(at: i), at: 0)
        }
        return pages.map(\.1)
    }
}

// MARK: - 그림 조각

/// 장표 한 장 — 16:9 카드에 제목 막대와 글줄.
private struct ArtSlide: View {
    var width: CGFloat = 120
    var tint: Color? = nil
    @Environment(\.leeoStyle) private var theme

    var body: some View {
        let accent = tint ?? theme.accent
        RoundedRectangle(cornerRadius: width * 0.06, style: .continuous)
            .fill(Color(.systemBackground))
            .frame(width: width, height: width * 9 / 16)
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: width * 0.05) {
                    Capsule().fill(accent).frame(width: width * 0.45, height: width * 0.06)
                    Capsule().fill(Color.secondary.opacity(0.35)).frame(width: width * 0.7, height: width * 0.04)
                    Capsule().fill(Color.secondary.opacity(0.35)).frame(width: width * 0.55, height: width * 0.04)
                }
                .padding(width * 0.09)
            }
            .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
    }
}

/// 모서리의 동그란 표식.
private struct ArtBadge: View {
    let systemImage: String
    var color: Color? = nil
    @Environment(\.leeoStyle) private var theme

    var body: some View {
        Image(systemName: systemImage)
            .font(.title3.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(color ?? theme.accent, in: Circle())
            .shadow(color: (color ?? theme.accent).opacity(0.4), radius: 6, y: 2)
    }
}

// MARK: - Plus

/// 발표 무제한: 발표 묶음이 줄줄이, 모서리에 ∞
private struct PresentationsArt: View {
    var body: some View {
        VStack(spacing: 10) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 10) {
                    ZStack {
                        ArtSlide(width: 64).offset(x: 6, y: -5).opacity(0.6)
                        ArtSlide(width: 64)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Capsule().fill(Color.primary.opacity(0.7)).frame(width: [90, 70, 110][row], height: 7)
                        Capsule().fill(Color.secondary.opacity(0.35)).frame(width: 50, height: 6)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(20)
        .overlay(alignment: .topTrailing) { ArtBadge(systemImage: "infinity").padding(14) }
    }
}

/// 또렷하게 보정: 흐리고 그늘진 장표 → 또렷한 장표
private struct EnhanceArt: View {
    var body: some View {
        HStack(spacing: 14) {
            ArtSlide(width: 110, tint: .gray)
                .overlay {
                    LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
                        .clipShape(RoundedRectangle(cornerRadius: 6.6, style: .continuous))
                }
                .blur(radius: 1.2)
                .saturation(0.2)
            Image(systemName: "arrow.right")
                .font(.title3.weight(.bold))
                .foregroundStyle(.secondary)
            ArtSlide(width: 110)
                .overlay(alignment: .topTrailing) { ArtBadge(systemImage: "wand.and.stars").offset(x: 14, y: -18) }
        }
        .padding(16)
    }
}

/// PDF 두 장 · 네 장씩: 두 장 든 쪽, 네 장 든 쪽
private struct PDFLayoutArt: View {
    var body: some View {
        HStack(spacing: 22) {
            page(columns: 1, count: 2)
            page(columns: 2, count: 4)
        }
        .padding(16)
    }

    private func page(columns: Int, count: Int) -> some View {
        let slide: CGFloat = columns == 1 ? 76 : 40
        return RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color(.systemBackground))
            .frame(width: 100, height: 140)
            .overlay {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(slide), spacing: 6), count: columns), spacing: 10) {
                    ForEach(0..<count, id: \.self) { _ in ArtSlide(width: slide) }
                }
            }
            .shadow(color: .black.opacity(0.1), radius: 5, y: 2)
    }
}

// MARK: - Pro

/// 기기 안 요약: 긴 글 → 반짝 → 세 줄
private struct SummaryArt: View {
    @Environment(\.leeoStyle) private var theme

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach([90, 76, 96, 70, 88, 60], id: \.self) { w in
                    Capsule().fill(Color.secondary.opacity(0.4)).frame(width: CGFloat(w), height: 5)
                }
            }
            .padding(12)
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Image(systemName: "sparkles")
                .font(.title.weight(.semibold))
                .foregroundStyle(theme.accent)
            VStack(alignment: .leading, spacing: 10) {
                ForEach([64, 80, 56], id: \.self) { w in
                    HStack(spacing: 6) {
                        Circle().fill(theme.accent).frame(width: 7, height: 7)
                        Capsule().fill(Color.primary.opacity(0.7)).frame(width: CGFloat(w), height: 6)
                    }
                }
            }
            .padding(12)
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .topTrailing) {
                Image(systemName: "lock.iphone")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Color.green, in: Circle())
                    .offset(x: 8, y: -8)
            }
        }
        .padding(16)
    }
}

/// 내보내기: 장표 묶음 → PPTX · MD 파일
private struct ExportArt: View {
    @Environment(\.leeoStyle) private var theme

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                ArtSlide(width: 96).offset(x: 8, y: -8).opacity(0.6)
                ArtSlide(width: 96)
            }
            Image(systemName: "arrow.right")
                .font(.title3.weight(.bold))
                .foregroundStyle(.secondary)
            VStack(spacing: 12) {
                file("PPTX", color: .orange)
                file("MD", color: theme.accent)
            }
        }
        .padding(16)
    }

    private func file(_ name: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "doc.fill").font(.title2).foregroundStyle(color)
            Text(verbatim: name).font(.caption.weight(.heavy)).foregroundStyle(color)
        }
        .frame(width: 72, height: 72)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 5, y: 2)
    }
}

/// iCloud 동기화: iPhone · iPad · Mac 이 같은 발표를
private struct SyncArt: View {
    @Environment(\.leeoStyle) private var theme

    var body: some View {
        ZStack {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 120, weight: .ultraLight))
                .foregroundStyle(theme.accent.opacity(0.25))
            HStack(alignment: .bottom, spacing: 18) {
                Image(systemName: "iphone").font(.system(size: 50))
                Image(systemName: "ipad.landscape").font(.system(size: 64))
                Image(systemName: "laptopcomputer").font(.system(size: 70))
            }
            .foregroundStyle(theme.accent)
        }
        .padding(16)
    }
}

/// Plus 의 모든 것: Plus 에서 열리는 셋을 한데
private struct EverythingInPlusArt: View {
    @Environment(\.leeoStyle) private var theme

    var body: some View {
        VStack(spacing: 14) {
            Text(verbatim: "Plus")
                .font(.headline.weight(.heavy))
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 14).padding(.vertical, 5)
                .background(theme.accent.opacity(0.14), in: Capsule())
            HStack(spacing: 16) {
                ForEach(["rectangle.stack.fill", "wand.and.stars", "doc.on.doc.fill"], id: \.self) { symbol in
                    Image(systemName: symbol)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(theme.accent)
                        .frame(width: 64, height: 64)
                        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(color: .black.opacity(0.06), radius: 5, y: 2)
                }
            }
            Image(systemName: "checkmark.seal.fill").font(.title).foregroundStyle(.green)
        }
        .padding(16)
    }
}
