import CloudKit
import Foundation

/// What the store reports, in order, on `events`.
enum RemoteSyncEvent: Sendable {
    /// Records the server sent: saved or changed, and removed. Keyed by record name.
    case changed(saved: [String: RemoteEntry], deleted: [String])
    /// The iCloud account went away or changed; the local mirror was emptied.
    case reset
    /// A fetch or send finished.
    case synced(Date)
    case failed(String)
}

/// What the Mac's mirror and the phone's client need from a store. `RemoteSyncStore` is the one
/// that talks to CloudKit; tests substitute one that records what it is given.
protocol RemoteStoring: Sendable {
    var events: AsyncStream<RemoteSyncEvent> { get }
    func start() async
    func stop() async
    func entries() async -> [String: RemoteEntry]
    func save<T: RemotePayload>(_ value: T) async throws
    func delete(_ name: String) async
    func fetchNow() async
    func sendNow() async
}

/// A local mirror of the `Remote` zone, kept in step with CloudKit by `CKSyncEngine`.
///
/// The owner saves and deletes values here; the engine sends them when it can and hands back what
/// other devices wrote. The mirror, the engine's state and the names still to send persist in one
/// file, so a relaunch resumes from its change token and loses no unsent change.
///
/// Create it only in a process that has the iCloud entitlement: `CKContainer` traps without it.
actor RemoteSyncStore: CKSyncEngineDelegate, RemoteStoring {
    private struct Saved: Codable {
        var state: CKSyncEngine.State.Serialization?
        var entries: [String: RemoteEntry] = [:]
        /// Saved or deleted here and not yet confirmed by the server.
        var unsent: Set<String> = []
        var zoneCreated = false
    }

    nonisolated let events: AsyncStream<RemoteSyncEvent>
    private let continuation: AsyncStream<RemoteSyncEvent>.Continuation
    private let database: CKDatabase
    private let fileURL: URL
    private var saved: Saved
    private var engine: CKSyncEngine?
    private var flush: Task<Void, Never>?
    /// Stopped for good. A later store owns the file, so this one changes and writes nothing more.
    private var stopped = false

    init(fileURL: URL, container: CKContainer = CKContainer(identifier: RemoteSchema.container)) {
        self.fileURL = fileURL
        self.database = container.privateCloudDatabase
        let data = try? Data(contentsOf: fileURL)
        self.saved = data.flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } ?? Saved()
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    func start() {
        guard engine == nil, !stopped else { return }
        var configuration = CKSyncEngine.Configuration(database: database, stateSerialization: saved.state, delegate: self)
        configuration.automaticallySync = true
        let engine = CKSyncEngine(configuration)
        self.engine = engine
        if !saved.zoneCreated { engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: RemoteSchema.zone))]) }
        // Whatever changed while stopped goes up now.
        let pending = saved.unsent.map { name -> CKSyncEngine.PendingRecordZoneChange in
            saved.entries[name] == nil ? .deleteRecord(recordID(name)) : .saveRecord(recordID(name))
        }
        if !pending.isEmpty { engine.state.add(pendingRecordZoneChanges: pending) }
    }

    func stop() {
        engine = nil
        write()
        stopped = true
        continuation.finish()
    }

    /// Everything the mirror holds, keyed by record name.
    func entries() -> [String: RemoteEntry] { saved.entries }

    func save<T: RemotePayload>(_ value: T) throws {
        guard !stopped else { return }
        var entry = try RemoteCodec.entry(value)
        guard entry.payload.count <= RemoteSchema.maxPayload else { throw CKError(.limitExceeded) }
        let name = value.recordName
        guard saved.entries[name]?.payload != entry.payload else { return }
        entry.systemFields = saved.entries[name]?.systemFields
        saved.entries[name] = entry
        saved.unsent.insert(name)
        persist()
        engine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID(name))])
    }

    func delete(_ name: String) {
        guard !stopped, saved.entries.removeValue(forKey: name) != nil else { return }
        saved.unsent.insert(name)
        persist()
        engine?.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID(name))])
    }

    /// Fetch now rather than when the engine next would: the phone while it is open, the Mac
    /// while it waits for messages.
    func fetchNow() async {
        do { try await engine?.fetchChanges() } catch { report(error) }
    }

    func sendNow() async {
        do { try await engine?.sendChanges() } catch { report(error) }
    }

    /// A fetch or send cut short, by the app going to the background, is not a failure.
    private func report(_ error: Error) {
        if error is CancellationError || (error as? CKError)?.code == .operationCancelled { return }
        continuation.yield(.failed(Self.describe(error)))
    }

    // MARK: CKSyncEngineDelegate

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            saved.state = update.stateSerialization
            persist()
        case .accountChange(let change):
            switch change.changeType {
            case .signIn: break
            case .signOut, .switchAccounts: reset()
            @unknown default: reset()
            }
        case .fetchedDatabaseChanges(let changes):
            if changes.deletions.contains(where: { $0.zoneID == RemoteSchema.zone }) { reset() }
        case .fetchedRecordZoneChanges(let changes):
            var changed: [String: RemoteEntry] = [:]
            for modification in changes.modifications {
                let record = modification.record
                let name = record.recordID.recordName
                // A change of ours not yet sent is newer than what the server has.
                guard record.recordID.zoneID == RemoteSchema.zone, !saved.unsent.contains(name),
                      let entry = Self.entry(of: record) else { continue }
                saved.entries[name] = entry
                changed[name] = entry
            }
            let deleted = changes.deletions.map(\.recordID.recordName).filter { !saved.unsent.contains($0) }
            for name in deleted { saved.entries[name] = nil }
            persist()
            if !changed.isEmpty || !deleted.isEmpty { continuation.yield(.changed(saved: changed, deleted: deleted)) }
        case .sentDatabaseChanges(let sent):
            if sent.savedZones.contains(where: { $0.zoneID == RemoteSchema.zone }) {
                saved.zoneCreated = true
                persist()
            }
            if let failure = sent.failedZoneSaves.first { continuation.yield(.failed(Self.describe(failure.error))) }
        case .sentRecordZoneChanges(let sent):
            for record in sent.savedRecords {
                let name = record.recordID.recordName
                guard saved.entries[name] != nil else { continue }
                saved.entries[name]?.systemFields = Self.systemFields(of: record)
                // Sent as it stands now, unless it changed again while in flight.
                if record.encryptedValues[RemoteSchema.payloadKey] as? Data == saved.entries[name]?.payload {
                    saved.unsent.remove(name)
                }
            }
            for id in sent.deletedRecordIDs where saved.entries[id.recordName] == nil {
                saved.unsent.remove(id.recordName)
            }
            for (id, error) in sent.failedRecordDeletes where error.code == .unknownItem {
                saved.unsent.remove(id.recordName)
            }
            for failure in sent.failedRecordSaves { recover(failure, engine: syncEngine) }
            persist()
        case .didFetchChanges, .didSendChanges:
            continuation.yield(.synced(Date()))
        default:
            break
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        // A save whose value has since been deleted here has nothing to send.
        let gone = pending.compactMap { change -> CKSyncEngine.PendingRecordZoneChange? in
            if case .saveRecord(let id) = change, saved.entries[id.recordName] == nil { return change }
            return nil
        }
        if !gone.isEmpty { syncEngine.state.remove(pendingRecordZoneChanges: gone) }
        let records = Dictionary(uniqueKeysWithValues: pending.compactMap { change -> (CKRecord.ID, CKRecord)? in
            guard case .saveRecord(let id) = change, let record = record(for: id) else { return nil }
            return (id, record)
        })
        let sendable = pending.filter { change in
            if case .saveRecord(let id) = change { return records[id] != nil }
            return true
        }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: sendable) { records[$0] }
    }

    // MARK: Private

    private func recover(_ failure: CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave, engine: CKSyncEngine) {
        let id = failure.record.recordID
        let name = id.recordName
        switch failure.error.code {
        case .serverRecordChanged:
            guard let server = failure.error.serverRecord, let ours = saved.entries[name] else { return }
            // A command is the one record two devices write: the phone makes it, the Mac marks
            // it handled. The handled one is never overwritten by a stale `pending` copy, which
            // is what a phone whose first save did land, unheard, would send again.
            if ours.type == .command, let theirs = Self.entry(of: server),
               theirs.decode(RemoteCommand.self)?.status != .pending, ours.decode(RemoteCommand.self)?.status == .pending {
                saved.entries[name] = theirs
                saved.unsent.remove(name)
                continuation.yield(.changed(saved: [name: theirs], deleted: []))
                return
            }
            // Every other record has one writer, so ours wins: take the server's tag and send again.
            saved.entries[name]?.systemFields = Self.systemFields(of: server)
            engine.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
        case .zoneNotFound:
            saved.zoneCreated = false
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: RemoteSchema.zone))])
            engine.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
        case .unknownItem:
            // Deleted on the server. A handled command stays gone; anything else is written anew.
            if saved.entries[name]?.type == .command {
                saved.entries[name] = nil
                saved.unsent.remove(name)
            } else {
                saved.entries[name]?.systemFields = nil
                engine.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
            }
        case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .notAuthenticated, .operationCancelled, .requestRateLimited:
            break // The engine retries these itself.
        default:
            continuation.yield(.failed(Self.describe(failure.error)))
        }
    }

    private func record(for id: CKRecord.ID) -> CKRecord? {
        guard let entry = saved.entries[id.recordName] else { return nil }
        let record = entry.systemFields.flatMap(Self.record(fromSystemFields:))
            ?? CKRecord(recordType: entry.type.rawValue, recordID: id)
        record[RemoteSchema.hostKey] = entry.host
        record.encryptedValues[RemoteSchema.payloadKey] = entry.payload
        return record
    }

    /// A fetched record as the mirror keeps it, or nil if it is not one of ours.
    private static func entry(of record: CKRecord) -> RemoteEntry? {
        guard let type = RemoteRecordType(rawValue: record.recordType),
              let host = record[RemoteSchema.hostKey] as? String,
              let payload = record.encryptedValues[RemoteSchema.payloadKey] as? Data else { return nil }
        return RemoteEntry(type: type, host: host, payload: payload, systemFields: systemFields(of: record))
    }

    private func recordID(_ name: String) -> CKRecord.ID { CKRecord.ID(recordName: name, zoneID: RemoteSchema.zone) }

    private func reset() {
        saved.entries = [:]
        saved.unsent = []
        saved.zoneCreated = false
        persist()
        continuation.yield(.reset)
    }

    /// Written a moment later, once for a burst of changes: a busy tick saves many turns.
    private func persist() {
        guard flush == nil, !stopped else { return }
        flush = Task {
            try? await Task.sleep(for: .seconds(1))
            write()
        }
    }

    private func write() {
        flush?.cancel()
        flush = nil
        guard !stopped else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(saved).write(to: fileURL, options: [.atomic])
        } catch {
            continuation.yield(.failed(error.localizedDescription))
        }
    }

    private static func systemFields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    private static func record(fromSystemFields data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }

    static func describe(_ error: Error) -> String {
        guard let error = error as? CKError else { return error.localizedDescription }
        switch error.code {
        case .notAuthenticated: return String(localized: "Sign in to iCloud to sync.")
        case .quotaExceeded: return String(localized: "Your iCloud storage is full.")
        case .networkFailure, .networkUnavailable: return String(localized: "iCloud can’t be reached.")
        default: return error.localizedDescription
        }
    }
}
