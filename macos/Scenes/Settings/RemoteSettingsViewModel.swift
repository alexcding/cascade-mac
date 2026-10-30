import Foundation
import Observation

/// Settings → Remote: whether other Macs may connect to this one, the code a Mac pairs with, the
/// Macs paired with this one (which may read its sessions), and the Macs this one paired with
/// (whose sessions the sidebar shows).
///
/// Nothing tries an unreachable Mac on a timer: while this section is shown, each paired Mac not
/// answering is tried once, and again whenever Bonjour sees it, at the address it is seen at.
/// Bonjour browses only while the section is shown. This Mac is advertised whenever other Macs may
/// connect (`AppViewModel.advertiseHost`, told of each status read through `onStatus`), so a Mac
/// paired with it finds it again after its address or port changed.
@MainActor @Observable final class RemoteSettingsViewModel {
    private(set) var status: RemoteStatus?
    private(set) var clients: [RemoteClient] = []
    private(set) var peers: [RemotePeer] = []
    /// The Macs Bonjour sees that are not paired with this one yet.
    private(set) var nearby: [RemoteBonjour.Sighting] = []
    /// The code shown while a pairing window is open, and when it closes.
    private(set) var pairingCode: String?
    private(set) var pairingCloses: Date?
    private(set) var attemptsLeft = 3
    /// A pairing this Mac is making with another, and why the last one failed.
    private(set) var pairing = false
    private(set) var pairError: String?
    private(set) var saving = false
    private(set) var error: String?
    private(set) var retired = false
    private(set) var active = false

    @ObservationIgnored private var service: (any RemoteServing)?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var sightings: [RemoteBonjour.Sighting] = []
    /// What was tried this time the section was shown: each Mac, at each address.
    @ObservationIgnored private var tried: Set<String> = []
    @ObservationIgnored private var browser: RemoteBrowser?
    /// Each status read or set, for the app's advertiser.
    @ObservationIgnored var onStatus: (RemoteStatus) -> Void = { _ in }
    /// Ends the code when its window closes, shown or not: the backend says nothing then.
    @ObservationIgnored private var expiry: Task<Void, Never>?
    @ObservationIgnored private let makeBrowser: @MainActor () -> RemoteBrowser?
    @ObservationIgnored private let name: @MainActor () -> String?

    init(makeBrowser: @escaping @MainActor () -> RemoteBrowser? = { RemoteBrowser() },
         name: @escaping @MainActor () -> String? = { RemoteBonjour.computerName() }) {
        self.makeBrowser = makeBrowser; self.name = name
    }

    var enabled: Bool { status?.enabled == true }
    /// Where another Mac reaches this one when it cannot find it: for Pair by address.
    var address: String? {
        guard enabled, let port = status?.port, let host = RemoteBonjour.localHost() else { return nil }
        return "\(host):\(port)"
    }

    func connect(_ service: (any RemoteServing)?) {
        guard !retired else { return }
        self.service = service; generation = UUID()
        saving = false; pairing = false; error = nil; pairError = nil
        clearPairing()
        if service == nil { status = nil; clients = []; peers = []; return }
        if active { refresh() }
    }

    /// The section is shown, or stopped being: Bonjour and the tries follow it.
    func setActive(_ value: Bool) {
        guard !retired, active != value else { return }
        active = value
        if value {
            tried = []
            refresh()
            if browser == nil, let browser = makeBrowser() {
                browser.onChange = { [weak self] in self?.seen($0) }
                browser.start()
                self.browser = browser
            }
        } else {
            browser?.stop(); browser = nil
            sightings = []; nearby = []
        }
    }

    func refresh() {
        guard !retired, let service else { return }
        let token = generation
        Task { [weak self] in
            do {
                async let status = service.status()
                async let clients = service.clients()
                async let peers = service.peers()
                async let window = service.pairingWindow()
                let read = try await (status, clients, peers, window)
                guard let self, !self.retired, self.generation == token else { return }
                self.status = read.0; self.clients = read.1; self.error = nil
                self.onStatus(read.0)
                self.setPeers(read.2)
                self.windowRead(read.3)
            } catch {
                RemoteBonjour.log.error("settings read failed: \(error.localizedDescription, privacy: .public)")
                guard let self, !self.retired, self.generation == token else { return }
                self.error = error.localizedDescription
            }
        }
    }

    func setEnabled(_ value: Bool) async {
        guard !retired, !saving, let service else { return }
        let token = generation
        saving = true; error = nil
        defer { if generation == token { saving = false } }
        do {
            let updated = try await service.setEnabled(value)
            guard !retired, generation == token else { return }
            status = updated
            onStatus(updated)
            if !value { clearPairing() }
        } catch {
            if !retired, generation == token { self.error = error.localizedDescription }
        }
    }

    /// Opens a pairing window and shows its code.
    func openPairing() async {
        guard !retired, let service else { return }
        let token = generation
        error = nil
        do {
            let opened = try await service.openPairing(name: name())
            guard !retired, generation == token else { return }
            pairingCode = opened.code
            attemptsLeft = 3
            closes(in: opened.seconds)
        } catch {
            if !retired, generation == token { self.error = error.localizedDescription }
        }
    }

    func closePairing() async {
        guard !retired, let service else { return }
        clearPairing()
        try? await service.closePairing()
    }

    /// The code shown has run out: the backend refuses it from now on, so it goes.
    func pairingExpired() {
        guard let closes = pairingCloses, closes <= Date() else { return }
        clearPairing()
    }

    func revoke(_ client: RemoteClient) async {
        guard !retired, let service else { return }
        do { try await service.revoke(client: client.id) } catch { self.error = error.localizedDescription }
        refresh()
    }

    func forget(_ peer: RemotePeer) async {
        guard !retired, let service else { return }
        do { try await service.forget(peer: peer.id) } catch { self.error = error.localizedDescription }
        refresh()
    }

    /// Pairs with the Mac at `address` (one Bonjour saw, or one typed) using the code it shows.
    @discardableResult func pair(address: String, code: String) async -> Bool {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = code.filter(\.isNumber)
        guard !retired, !pairing, let service, !address.isEmpty, code.count == 6 else { return false }
        let token = generation
        pairing = true; pairError = nil
        defer { if generation == token { pairing = false } }
        do {
            let peer = try await service.pair(address: address, code: code, label: name())
            guard !retired, generation == token else { return false }
            // The answer says nothing of whether it answers: what was heard of that stands, and the
            // list is read again for the rest.
            if let index = peers.firstIndex(where: { $0.id == peer.id }) {
                var paired = peer
                paired.reach = peers[index].reach
                peers[index] = paired
            } else {
                var paired = peer
                paired.reach = .connecting
                peers.append(paired)
            }
            updateNearby()
            if active { refresh() }
            return true
        } catch {
            if !retired, generation == token { pairError = error.localizedDescription }
            return false
        }
    }

    /// The backend's remote events.
    func receive(_ event: ServerEvent) {
        guard !retired, service != nil else { return }
        switch event.type {
        case "remote-clients", "remote-peers", "remote-host":
            if active { refresh() }
        case "remote-pairing":
            readWindow()
        case "remote-peer":
            guard let id = event.peer, let index = peers.firstIndex(where: { $0.id == id }) else {
                if active { refresh() }
                return
            }
            peers[index].reach = event.reach.flatMap(RemotePeer.Reach.init(rawValue:)) ?? .offline
        default: break
        }
    }

    func retire() {
        guard !retired else { return }
        setActive(false)
        clearPairing()
        retired = true; service = nil; onStatus = { _ in }
    }

    func disconnect() {
        setActive(false)
        connect(nil)
    }

    // MARK: Private

    private func setPeers(_ listed: [RemotePeer]) {
        if peers != listed { peers = listed }
        updateNearby()
        tryUnreachable()
    }

    /// What Bonjour sees now; the browser calls it while the section shows.
    func seen(_ sightings: [RemoteBonjour.Sighting]) {
        guard !retired, active else { return }
        self.sightings = sightings
        updateNearby()
        tryUnreachable()
    }

    private func updateNearby() {
        let paired = Set(peers.map(\.id))
        let own = status?.fingerprint
        let next = sightings.filter { !paired.contains($0.id) && $0.id != own }
        if nearby != next { nearby = next }
    }

    /// Each paired Mac not answering is tried once while the section is shown, and at each
    /// address Bonjour sees it at.
    private func tryUnreachable() {
        guard active, let service else { return }
        for peer in peers where peer.reach == .offline || peer.reach == .changed {
            let address = sightings.first { $0.id == peer.id }?.address
            let key = "\(peer.id) \(address ?? "")"
            guard !tried.contains(key) else { continue }
            tried.insert(key)
            RemoteBonjour.log.notice("retry \(peer.name, privacy: .public) at \(address ?? "its known addresses", privacy: .public)")
            Task {
                do { try await service.connect(peer: peer.id, address: address) } catch {
                    RemoteBonjour.log.error("retry \(peer.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func readWindow() {
        guard let service else { return }
        let token = generation
        Task { [weak self] in
            guard let window = try? await service.pairingWindow() else { return }
            guard let self, !self.retired, self.generation == token else { return }
            self.windowRead(window)
        }
    }

    /// A window closed (a Mac paired, its attempts used up, or turned off) takes its code with it.
    private func windowRead(_ window: RemotePairingWindow) {
        if window.open {
            attemptsLeft = window.attemptsLeft
            if pairingCode != nil { closes(in: window.seconds) }
        } else if pairingCode != nil {
            clearPairing()
        }
    }

    private func closes(in seconds: Int) {
        pairingCloses = Date().addingTimeInterval(TimeInterval(seconds))
        expiry?.cancel()
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.pairingExpired()
        }
    }

    private func clearPairing() {
        pairingCode = nil; pairingCloses = nil; attemptsLeft = 3
        expiry?.cancel(); expiry = nil
    }
}
