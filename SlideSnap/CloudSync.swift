import CloudKit
import os

/// iCloud 동기화 레코드 하나를 가리킨다. CloudKit 레코드 이름은 "종류_UUID".
enum SyncRecordID: Hashable {
    case presentation(UUID)
    case slide(UUID)
    case recording(UUID)

    var recordName: String {
        switch self {
        case .presentation(let id): return "P_\(id.uuidString)"
        case .slide(let id): return "S_\(id.uuidString)"
        case .recording(let id): return "R_\(id.uuidString)"
        }
    }

    init?(recordName: String) {
        let parts = recordName.split(separator: "_", maxSplits: 1)
        guard parts.count == 2, let id = UUID(uuidString: String(parts[1])) else { return nil }
        switch parts[0] {
        case "P": self = .presentation(id)
        case "S": self = .slide(id)
        case "R": self = .recording(id)
        default: return nil
        }
    }

    var ckRecordID: CKRecord.ID {
        CKRecord.ID(recordName: recordName, zoneID: CloudSync.zoneID)
    }
}

/// 발표·장표·녹음을 같은 Apple ID의 iPhone·iPad·Mac 사이에서 맞춘다 (CKSyncEngine).
///
/// - 레코드는 세 종류다. `Presentation`(제목·장표 순서·요약), `Slide`(장표 정보 + 이미지 파일),
///   `Recording`(녹음 정보·받아쓰기 + 음성 파일). 모두 `payload` 필드에 JSON을 담고 파일은 CKAsset으로 올린다.
/// - 같은 레코드를 두 기기에서 고치면 나중에 보낸 쪽이 이긴다.
/// - 장표가 발표보다 먼저 도착할 수 있어, 아직 발표가 없는 장표·녹음은 잠시 맡아 두었다가 발표가 오면 붙인다.
/// - 사진·녹음이 사용자의 iCloud 용량을 쓰므로 기본은 꺼 두고, 사용자가 켤 때만 올린다.
@MainActor
final class CloudSync: ObservableObject {

    static let containerID = "iCloud.com.leeo.slidesnap"
    nonisolated static let zoneID = CKRecordZone.ID(zoneName: "SlideSnap", ownerName: CKCurrentUserDefaultName)
    private static let enabledKey = "sync.enabled"

    @Published private(set) var isEnabled: Bool
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var lastError: String?

    private weak var store: Store?
    private var engine: CKSyncEngine?
    private var metadata = Metadata()
    private let log = Logger(subsystem: "com.leeo.slidesnap", category: "sync")

    /// 엔진 상태와 레코드 시스템 필드, 아직 발표가 도착하지 않은 장표·녹음을 파일로 남겨 둔다.
    private struct Metadata: Codable {
        var engineState: CKSyncEngine.State.Serialization?
        var systemFields: [String: Data] = [:]
        var orphanSlides: [UUID: [Slide]] = [:]
        var orphanRecordings: [UUID: [Recording]] = [:]
        /// iCloud에서 받은 발표별 장표 순서. 장표가 늦게 도착해도 제자리에 끼우려고 쓴다.
        var slideOrder: [UUID: [UUID]] = [:]
        var lastSyncedAt: Date?
    }

    private struct PresentationPayload: Codable {
        var title: String
        var createdAt: Date
        var slideOrder: [UUID]
        var summary: PresentationSummary?
    }

    private struct SlidePayload: Codable {
        var presentationID: UUID
        var slide: Slide
    }

    private struct RecordingPayload: Codable {
        var presentationID: UUID
        var recording: Recording
    }

    private var metadataURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cloud-sync.json")
    }

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    /// 앱 시작 시 저장소와 연결한다. 동기화가 켜져 있으면 엔진을 띄운다.
    func attach(_ store: Store) {
        guard self.store == nil else { return }
        self.store = store
        store.sync = self
        guard isEnabled else { return }
        loadMetadata()
        lastSyncedAt = metadata.lastSyncedAt
        startEngine()
    }

    // MARK: - 켜기 / 끄기

    /// 동기화를 켠다. iCloud에 로그인되어 있지 않으면 에러 문구를 남기고 켜지 않는다.
    func enable() async {
        guard !isEnabled else { return }
        lastError = nil
        do {
            let status = try await CKContainer(identifier: Self.containerID).accountStatus()
            guard status == .available else {
                lastError = String(localized: "iCloud에 로그인되어 있지 않아요. 설정에서 iCloud에 로그인한 뒤 다시 켜 주세요.")
                return
            }
        } catch {
            lastError = error.localizedDescription
            return
        }
        isEnabled = true
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        metadata = Metadata()
        saveMetadata()
        startEngine()
        // 처음 켜면 이 기기의 기존 데이터를 모두 올린다(다른 기기 데이터와는 합쳐진다).
        engine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
        if let store { track(save: store.allRecordIDs) }
        await syncNow()
    }

    /// 동기화를 끈다. 이 기기와 iCloud의 데이터는 그대로 두고 더 이상 주고받지 않는다.
    func disable() {
        isEnabled = false
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        engine = nil
        metadata = Metadata()
        try? FileManager.default.removeItem(at: metadataURL)
        lastSyncedAt = nil
        lastError = nil
    }

    /// 지금 바로 주고받는다(앱이 앞으로 올 때 등).
    func syncNow() async {
        guard let engine else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            try await engine.fetchChanges()
            try await engine.sendChanges()
            lastError = nil
        } catch {
            log.error("sync failed: \(error.localizedDescription, privacy: .public)")
            lastError = Self.message(for: error)
        }
    }

    // MARK: - 로컬 변경 알림

    func track(save: [SyncRecordID] = [], delete: [SyncRecordID] = []) {
        guard let engine else { return }
        var changes: [CKSyncEngine.PendingRecordZoneChange] = []
        changes += save.map { .saveRecord($0.ckRecordID) }
        changes += delete.map { .deleteRecord($0.ckRecordID) }
        guard !changes.isEmpty else { return }
        for id in delete { metadata.systemFields[id.recordName] = nil }
        engine.state.add(pendingRecordZoneChanges: changes)
    }

    // MARK: - 엔진

    private func startEngine() {
        let configuration = CKSyncEngine.Configuration(
            database: CKContainer(identifier: Self.containerID).privateCloudDatabase,
            stateSerialization: metadata.engineState,
            delegate: self
        )
        engine = CKSyncEngine(configuration)
    }

    private func loadMetadata() {
        guard let data = try? Data(contentsOf: metadataURL),
              let decoded = try? JSONDecoder().decode(Metadata.self, from: data) else { return }
        metadata = decoded
    }

    private func saveMetadata() {
        guard isEnabled, let data = try? JSONEncoder().encode(metadata) else { return }
        try? data.write(to: metadataURL, options: .atomic)
    }

    private static func message(for error: Error) -> String {
        if let ck = error as? CKError {
            switch ck.code {
            case .quotaExceeded:
                return String(localized: "iCloud 저장 공간이 부족해요.")
            case .networkUnavailable, .networkFailure:
                return String(localized: "인터넷에 연결되면 다시 동기화할게요.")
            case .notAuthenticated:
                return String(localized: "iCloud에 로그인되어 있지 않아요.")
            default:
                break
            }
        }
        return error.localizedDescription
    }

    // MARK: - 레코드 만들기 (올리기)

    private func makeRecord(for recordID: CKRecord.ID) -> CKRecord? {
        guard let store, let id = SyncRecordID(recordName: recordID.recordName) else { return nil }
        let encoder = JSONEncoder()

        switch id {
        case .presentation(let pid):
            guard let presentation = store.presentations.first(where: { $0.id == pid }) else { return nil }
            let payload = PresentationPayload(
                title: presentation.title,
                createdAt: presentation.createdAt,
                slideOrder: presentation.slides.map(\.id),
                summary: presentation.summary
            )
            guard let data = try? encoder.encode(payload) else { return nil }
            let record = baseRecord(type: "Presentation", id: recordID)
            record["payload"] = data as NSData
            return record

        case .slide(let sid):
            guard let (presentation, slide) = findSlide(sid, in: store) else { return nil }
            guard let data = try? encoder.encode(SlidePayload(presentationID: presentation.id, slide: slide)) else { return nil }
            let record = baseRecord(type: "Slide", id: recordID)
            record["payload"] = data as NSData
            record["original"] = asset(store.imageURL(slide.originalFile))
            record["corrected"] = asset(store.imageURL(slide.correctedFile))
            record["thumb"] = asset(store.imageURL(slide.thumbFile))
            record["enhanced"] = slide.enhancedFile.flatMap { asset(store.imageURL($0)) }
            return record

        case .recording(let rid):
            guard let (presentation, recording) = findRecording(rid, in: store) else { return nil }
            guard let data = try? encoder.encode(RecordingPayload(presentationID: presentation.id, recording: recording)) else { return nil }
            let record = baseRecord(type: "Recording", id: recordID)
            record["payload"] = data as NSData
            record["audio"] = asset(store.audioURL(recording.file))
            return record
        }
    }

    /// 전에 주고받은 적 있는 레코드면 그 시스템 필드(변경 태그)를 살려 충돌 없이 덮어쓴다.
    private func baseRecord(type: CKRecord.RecordType, id: CKRecord.ID) -> CKRecord {
        if let data = metadata.systemFields[id.recordName],
           let coder = try? NSKeyedUnarchiver(forReadingFrom: data) {
            coder.requiresSecureCoding = true
            let record = CKRecord(coder: coder)
            coder.finishDecoding()
            if let record, record.recordType == type { return record }
        }
        return CKRecord(recordType: type, recordID: id)
    }

    private func asset(_ url: URL) -> CKAsset? {
        FileManager.default.fileExists(atPath: url.path) ? CKAsset(fileURL: url) : nil
    }

    private func remember(_ record: CKRecord) {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        metadata.systemFields[record.recordID.recordName] = coder.encodedData
    }

    private func findSlide(_ id: UUID, in store: Store) -> (Presentation, Slide)? {
        for presentation in store.presentations {
            if let slide = presentation.slides.first(where: { $0.id == id }) { return (presentation, slide) }
        }
        return nil
    }

    private func findRecording(_ id: UUID, in store: Store) -> (Presentation, Recording)? {
        for presentation in store.presentations {
            if let recording = presentation.allRecordings.first(where: { $0.id == id }) { return (presentation, recording) }
        }
        return nil
    }

    // MARK: - 받은 레코드 반영 (내려받기)

    private func apply(_ record: CKRecord) {
        guard let store, let id = SyncRecordID(recordName: record.recordID.recordName),
              let data = record["payload"] as? Data else { return }
        remember(record)
        let decoder = JSONDecoder()

        switch id {
        case .presentation(let pid):
            guard let payload = try? decoder.decode(PresentationPayload.self, from: data) else { return }
            applyPresentation(pid, payload, store: store)
        case .slide:
            guard let payload = try? decoder.decode(SlidePayload.self, from: data) else { return }
            // 임시 파일은 이벤트 처리가 끝나면 사라지므로 바로 옮겨 둔다.
            copyAsset(record["original"], to: store.imageURL(payload.slide.originalFile))
            copyAsset(record["corrected"], to: store.imageURL(payload.slide.correctedFile))
            copyAsset(record["thumb"], to: store.imageURL(payload.slide.thumbFile))
            if let enhanced = payload.slide.enhancedFile {
                copyAsset(record["enhanced"], to: store.imageURL(enhanced))
            }
            applySlide(payload, store: store)
        case .recording:
            guard let payload = try? decoder.decode(RecordingPayload.self, from: data) else { return }
            copyAsset(record["audio"], to: store.audioURL(payload.recording.file))
            applyRecording(payload, store: store)
        }
    }

    private func copyAsset(_ value: CKRecordValue?, to destination: URL) {
        guard let source = (value as? CKAsset)?.fileURL else { return }
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        try? fm.copyItem(at: source, to: destination)
    }

    private func applyPresentation(_ pid: UUID, _ payload: PresentationPayload, store: Store) {
        metadata.slideOrder[pid] = payload.slideOrder
        let orphanSlides = metadata.orphanSlides.removeValue(forKey: pid) ?? []
        let orphanRecordings = metadata.orphanRecordings.removeValue(forKey: pid) ?? []

        store.applyFromSync { presentations in
            if let index = presentations.firstIndex(where: { $0.id == pid }) {
                presentations[index].title = payload.title
                presentations[index].createdAt = payload.createdAt
                presentations[index].summary = payload.summary
                presentations[index].slides = Self.ordered(presentations[index].slides + orphanSlides, by: payload.slideOrder)
                if !orphanRecordings.isEmpty {
                    presentations[index].recordings = presentations[index].allRecordings + orphanRecordings
                }
            } else {
                let presentation = Presentation(
                    id: pid,
                    title: payload.title,
                    createdAt: payload.createdAt,
                    slides: Self.ordered(orphanSlides, by: payload.slideOrder),
                    recordings: orphanRecordings.isEmpty ? nil : orphanRecordings,
                    summary: payload.summary
                )
                // 목록은 최근 발표가 위 — 만든 시각 순서에 맞춰 끼운다.
                let insertAt = presentations.firstIndex(where: { $0.createdAt < payload.createdAt }) ?? presentations.count
                presentations.insert(presentation, at: insertAt)
            }
        }
    }

    private func applySlide(_ payload: SlidePayload, store: Store) {
        let slide = payload.slide
        let pid = payload.presentationID
        guard store.presentations.contains(where: { $0.id == pid }) else {
            var orphans = metadata.orphanSlides[pid] ?? []
            orphans.removeAll { $0.id == slide.id }
            orphans.append(slide)
            metadata.orphanSlides[pid] = orphans
            return
        }
        var staleFiles: [Slide] = []
        let order = metadata.slideOrder[pid]
        store.applyFromSync { presentations in
            // 다른 발표에 있던 장표(합치기)면 그쪽에서 뺀다.
            for index in presentations.indices where presentations[index].id != pid {
                presentations[index].slides.removeAll { $0.id == slide.id }
            }
            guard let index = presentations.firstIndex(where: { $0.id == pid }) else { return }
            if let sIndex = presentations[index].slides.firstIndex(where: { $0.id == slide.id }) {
                staleFiles.append(presentations[index].slides[sIndex])
                presentations[index].slides[sIndex] = slide
            } else if let order {
                presentations[index].slides = Self.ordered(presentations[index].slides + [slide], by: order)
            } else {
                presentations[index].slides.append(slide)
            }
        }
        // 다시 보정하면 파일 이름이 바뀌므로 더 이상 쓰지 않는 예전 파일을 지운다.
        let keep = Set(Self.files(of: slide))
        for old in staleFiles {
            for file in Self.files(of: old) where !keep.contains(file) {
                try? FileManager.default.removeItem(at: store.imageURL(file))
            }
        }
    }

    private func applyRecording(_ payload: RecordingPayload, store: Store) {
        let recording = payload.recording
        let pid = payload.presentationID
        guard store.presentations.contains(where: { $0.id == pid }) else {
            var orphans = metadata.orphanRecordings[pid] ?? []
            orphans.removeAll { $0.id == recording.id }
            orphans.append(recording)
            metadata.orphanRecordings[pid] = orphans
            return
        }
        store.applyFromSync { presentations in
            for index in presentations.indices where presentations[index].id != pid {
                presentations[index].recordings?.removeAll { $0.id == recording.id }
            }
            guard let index = presentations.firstIndex(where: { $0.id == pid }) else { return }
            var recordings = presentations[index].allRecordings
            if let rIndex = recordings.firstIndex(where: { $0.id == recording.id }) {
                recordings[rIndex] = recording
            } else {
                recordings.append(recording)
                recordings.sort { $0.startedAt < $1.startedAt }
            }
            presentations[index].recordings = recordings
        }
    }

    private func applyDeletion(_ recordID: CKRecord.ID) {
        guard let store, let id = SyncRecordID(recordName: recordID.recordName) else { return }
        metadata.systemFields[recordID.recordName] = nil

        switch id {
        case .presentation(let pid):
            metadata.slideOrder[pid] = nil
            metadata.orphanSlides[pid] = nil
            metadata.orphanRecordings[pid] = nil
            guard let presentation = store.presentations.first(where: { $0.id == pid }) else { return }
            // 합치기로 다른 발표에 옮겨 간 장표는 그 발표에서 다시 올 수 있지만,
            // 여기서 지운 파일은 장표 레코드가 다시 오면 함께 내려받는다.
            presentation.slides.forEach { store.removeLocalFiles(of: $0) }
            presentation.allRecordings.forEach { store.removeLocalFiles(of: $0) }
            store.applyFromSync { $0.removeAll { $0.id == pid } }
        case .slide(let sid):
            for key in metadata.orphanSlides.keys { metadata.orphanSlides[key]?.removeAll { $0.id == sid } }
            guard let (_, slide) = findSlide(sid, in: store) else { return }
            store.removeLocalFiles(of: slide)
            store.applyFromSync { presentations in
                for index in presentations.indices { presentations[index].slides.removeAll { $0.id == sid } }
            }
        case .recording(let rid):
            for key in metadata.orphanRecordings.keys { metadata.orphanRecordings[key]?.removeAll { $0.id == rid } }
            guard let (_, recording) = findRecording(rid, in: store) else { return }
            store.removeLocalFiles(of: recording)
            store.applyFromSync { presentations in
                for index in presentations.indices { presentations[index].recordings?.removeAll { $0.id == rid } }
            }
        }
    }

    /// 장표를 주어진 순서대로 정렬한다. 순서에 없는 장표는 원래 순서를 지켜 뒤에 둔다.
    private static func ordered(_ slides: [Slide], by order: [UUID]) -> [Slide] {
        var seen = Set<UUID>()
        let unique = slides.reversed().filter { seen.insert($0.id).inserted }.reversed()
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return unique.enumerated()
            .sorted { lhs, rhs in
                let l = rank[lhs.element.id] ?? order.count + lhs.offset
                let r = rank[rhs.element.id] ?? order.count + rhs.offset
                return l < r
            }
            .map(\.element)
    }

    private static func files(of slide: Slide) -> [String] {
        [slide.originalFile, slide.correctedFile, slide.thumbFile] + (slide.enhancedFile.map { [$0] } ?? [])
    }
}

// MARK: - CKSyncEngineDelegate

extension CloudSync: CKSyncEngineDelegate {

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            metadata.engineState = update.stateSerialization

        case .accountChange(let change):
            switch change.changeType {
            case .signIn:
                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
                if let store { track(save: store.allRecordIDs) }
            case .signOut, .switchAccounts:
                // 다른 계정의 기록이 섞이지 않도록 동기화 기록만 비운다(이 기기의 발표는 그대로).
                metadata = Metadata()
            @unknown default:
                break
            }

        case .fetchedDatabaseChanges(let changes):
            if changes.deletions.contains(where: { $0.zoneID == Self.zoneID }) {
                // 다른 기기에서 iCloud 데이터를 지웠다 — 이 기기 것을 다시 올릴 준비만 한다.
                metadata.systemFields = [:]
            }

        case .fetchedRecordZoneChanges(let changes):
            for modification in changes.modifications {
                apply(modification.record)
            }
            for deletion in changes.deletions {
                applyDeletion(deletion.recordID)
            }

        case .sentRecordZoneChanges(let sent):
            for record in sent.savedRecords {
                remember(record)
            }
            var retry: [CKSyncEngine.PendingRecordZoneChange] = []
            for failure in sent.failedRecordSaves {
                let recordID = failure.record.recordID
                switch failure.error.code {
                case .serverRecordChanged:
                    // 다른 기기가 먼저 고쳤다 — 서버 버전 태그를 받아 이 기기 내용으로 다시 보낸다.
                    if let server = failure.error.serverRecord { remember(server) }
                    retry.append(.saveRecord(recordID))
                case .zoneNotFound:
                    syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
                    metadata.systemFields[recordID.recordName] = nil
                    retry.append(.saveRecord(recordID))
                case .unknownItem:
                    metadata.systemFields[recordID.recordName] = nil
                    retry.append(.saveRecord(recordID))
                case .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited, .zoneBusy:
                    break   // 엔진이 알아서 다시 보낸다
                default:
                    log.error("save failed \(recordID.recordName, privacy: .public): \(failure.error.localizedDescription, privacy: .public)")
                    lastError = Self.message(for: failure.error)
                }
            }
            if !retry.isEmpty { syncEngine.state.add(pendingRecordZoneChanges: retry) }

        case .didFetchChanges, .didSendChanges:
            lastSyncedAt = Date()
            metadata.lastSyncedAt = lastSyncedAt

        default:
            break
        }
        saveMetadata()
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !changes.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { recordID in
            await self.makeRecord(for: recordID)
        }
    }
}
