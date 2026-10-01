import SwiftUI

/// 발표 노트 — AI 요약, 녹음 목록, 받아쓰기를 한곳에서 다룬다.
struct PresentationNotesView: View {

    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss

    let presentationID: UUID

    @StateObject private var playback = AudioPlayback()

    @State private var summarizing = false
    @State private var summaryProgress: Double = 0
    @State private var transcribingID: UUID?
    @State private var transcribeProgress: Double?
    @State private var errorMessage: String?
    @State private var deletingRecording: Recording?
    @AppStorage("transcribe.language") private var transcribeLanguage = Transcriber.defaultLanguage

    private var presentation: Presentation? { store.presentation(presentationID) }

    var body: some View {
        NavigationStack {
            List {
                if let presentation {
                    summarySection(presentation)
                    recordingsSection(presentation)
                }
            }
            .navigationTitle("발표 노트")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("닫기") { dismiss() }
                }
            }
            .alert("할 수 없어요", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("확인", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .confirmationDialog(
                "이 녹음을 삭제할까요?",
                isPresented: Binding(get: { deletingRecording != nil }, set: { if !$0 { deletingRecording = nil } }),
                titleVisibility: .visible
            ) {
                Button("삭제", role: .destructive) {
                    if let recording = deletingRecording {
                        if playback.recordingID == recording.id { playback.stop() }
                        store.deleteRecording(recording.id, from: presentationID)
                    }
                }
                Button("취소", role: .cancel) {}
            } message: {
                Text("받아쓴 내용도 함께 삭제됩니다.")
            }
            .onDisappear { playback.stop() }
        }
    }

    // MARK: - AI 요약

    @ViewBuilder
    private func summarySection(_ presentation: Presentation) -> some View {
        Section {
            if summarizing {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: summaryProgress)
                    Text("장표와 발표 내용을 읽고 요약하는 중…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else if let summary = presentation.summary {
                VStack(alignment: .leading, spacing: 12) {
                    Text(summary.overview)
                        .font(.body)
                        .textSelection(.enabled)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(summary.keyPoints.enumerated()), id: \.offset) { _, point in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.footnote)
                                    .foregroundStyle(.tint)
                                Text(point)
                                    .font(.subheadline)
                            }
                        }
                    }
                    if !summary.keywords.isEmpty {
                        KeywordFlow(keywords: summary.keywords)
                    }
                }
                .padding(.vertical, 4)
                Button {
                    summarize(presentation)
                } label: {
                    Label("다시 요약하기", systemImage: "arrow.clockwise")
                }
            } else {
                let status = Summarizer.status
                if status == .available {
                    Button {
                        summarize(presentation)
                    } label: {
                        Label("AI로 요약하기", systemImage: "sparkles")
                    }
                } else {
                    Label(status.message, systemImage: "sparkles")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("AI 요약")
        } footer: {
            if presentation.summary == nil && !summarizing {
                Text("장표 글자와 받아쓴 발표 내용으로 핵심만 정리해요. 기기 안에서 처리되어 밖으로 나가지 않아요.")
            }
        }
    }

    private func summarize(_ presentation: Presentation) {
        summarizing = true
        summaryProgress = 0
        Task {
            do {
                let summary = try await Summarizer.summarize(presentation) { progress in
                    summaryProgress = progress
                }
                store.setSummary(summary, presentationID: presentationID)
            } catch {
                errorMessage = error.localizedDescription
            }
            summarizing = false
        }
    }

    // MARK: - 녹음

    @ViewBuilder
    private func recordingsSection(_ presentation: Presentation) -> some View {
        Section {
            if presentation.allRecordings.isEmpty {
                Label("촬영 화면 위쪽의 '녹음'을 켜면 장표를 찍는 동안 발표를 함께 녹음해요.", systemImage: "mic")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(presentation.allRecordings) { recording in
                    recordingRow(recording)
                }
                Picker("받아쓰기 언어", selection: $transcribeLanguage) {
                    ForEach(Transcriber.languages, id: \.id) { language in
                        Text(language.label).tag(language.id)
                    }
                }
            }
        } header: {
            Text("녹음 목록")
        } footer: {
            if !presentation.allRecordings.isEmpty {
                Text("받아쓰면 장표마다 그때 한 말을 볼 수 있고, 검색과 AI 요약에도 쓰여요.")
            }
        }
    }

    private func recordingRow(_ recording: Recording) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    togglePlay(recording)
                } label: {
                    Image(systemName: playback.recordingID == recording.id && playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(playback.recordingID == recording.id && playback.isPlaying ? Text("일시 정지") : Text("재생"))

                VStack(alignment: .leading, spacing: 2) {
                    Text(recording.startedAt.formatted(date: .omitted, time: .shortened))
                        .font(.headline)
                    Text(recording.duration.clockText)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                transcriptBadge(recording)
            }

            if playback.recordingID == recording.id {
                Slider(
                    value: Binding(get: { playback.currentTime }, set: { playback.seek(to: $0) }),
                    in: 0...max(playback.duration, 1)
                )
            }

            if transcribingID == recording.id {
                if let transcribeProgress {
                    ProgressView(value: transcribeProgress)
                } else {
                    ProgressView()
                }
            }
        }
        .padding(.vertical, 4)
        .swipeActions {
            Button(role: .destructive) {
                deletingRecording = recording
            } label: {
                Label("삭제", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func transcriptBadge(_ recording: Recording) -> some View {
        if transcribingID == recording.id {
            Text("받아쓰는 중…")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if recording.transcript != nil {
            Menu {
                Button {
                    transcribe(recording)
                } label: {
                    Label("다시 받아쓰기", systemImage: "arrow.clockwise")
                }
            } label: {
                Label("받아씀", systemImage: "text.bubble.fill")
                    .font(.caption.weight(.semibold))
            }
        } else {
            Button {
                transcribe(recording)
            } label: {
                Label("받아쓰기", systemImage: "text.bubble")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .disabled(transcribingID != nil)
        }
    }

    private func togglePlay(_ recording: Recording) {
        if playback.recordingID == recording.id, playback.isPlaying {
            playback.pause()
            return
        }
        playback.load(recording, url: store.audioURL(recording.file))
        playback.play()
    }

    private func transcribe(_ recording: Recording) {
        transcribingID = recording.id
        transcribeProgress = nil
        let language = transcribeLanguage
        let url = store.audioURL(recording.file)
        Task {
            // 긴 녹음은 몇 분 걸릴 수 있어 잠깐 앱을 벗어나도 이어서 하게 한다.
            let background = UIApplication.shared.beginBackgroundTask()
            defer { UIApplication.shared.endBackgroundTask(background) }
            do {
                let segments = try await Transcriber.transcribe(url: url, localeID: language) { progress in
                    Task { @MainActor in transcribeProgress = progress }
                }
                store.setTranscript(segments, locale: language, recordingID: recording.id, presentationID: presentationID)
            } catch {
                errorMessage = error.localizedDescription
            }
            transcribingID = nil
            transcribeProgress = nil
        }
    }
}

/// 키워드를 줄바꿈되는 칩으로 보여 준다.
private struct KeywordFlow: View {
    let keywords: [String]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(keywords, id: \.self) { keyword in
                Text(keyword)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                    .foregroundStyle(.tint)
            }
        }
    }
}

/// 가로로 채우다 넘치면 다음 줄로 넘기는 레이아웃.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews, width: bounds.width)
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !current.indices.isEmpty && current.width + spacing + size.width > width {
                rows.append(current)
                current = Row(y: current.y + current.height + spacing)
            }
            current.width += (current.indices.isEmpty ? 0 : spacing) + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
