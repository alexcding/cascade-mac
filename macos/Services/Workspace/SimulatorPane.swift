import AppKit
import AVFoundation
import Observation

// The Simulator pane: a session's simulator, streamed by the backend's device layer and driven
// from the pane. One model per session context, keyed by the session's worktree (the owner every
// agent in the session shares). The backend keeps which device the owner watches and pushes each
// change as a `device` event; the model shows the newest state, reads the video while the pane is
// on screen, and sends the user's clicks and keys.

/// What reads a device's video: a `DeviceFrameConnection`, or a recorder in tests.
protocol DeviceStreamConnecting: AnyObject {
    func start()
    func stop()
    func requestKeyframe()
}
extension DeviceFrameConnection: DeviceStreamConnecting {}

typealias DeviceStreamConnector = @MainActor (_ socketPath: String, _ udid: String, _ sink: any DeviceSampleSink,
                                              _ events: DeviceFrameConnection.Events) -> any DeviceStreamConnecting

@MainActor @Observable final class SimulatorPaneModel {
    /// A device the user picked, shown until the backend's state answers the pick: a cold boot takes
    /// most of a minute, and a pane that went on naming no device looked as if the click was lost.
    struct Pending: Equatable {
        let device: DeviceDescriptor
        /// The attachment the pick was made against. Once the state names anything else, the
        /// backend has answered, with this device or one an agent claimed meanwhile.
        let supersedes: String?
    }
    /// Cascade already runs as many simulators as it boots: one of them must go first.
    struct BootLimit: Equatable {
        let limit: Int
        let candidates: [DeviceDescriptor]
        let udid: String
        let name: String
    }

    /// The session's worktree, as the backend keys it.
    let owner: String
    private(set) var state: OwnerDeviceState?
    private(set) var loadError: String?
    /// An action of the user's that failed: shown until the next one.
    private(set) var actionError: String?
    /// An action of the user's is under way. Actions may overlap (a boot is slow, a detach is not),
    /// so it is a count, and the first to finish does not clear it for the others.
    var busy: Bool { actionsRunning > 0 }
    private var actionsRunning = 0
    private(set) var pending: Pending?
    private(set) var bootLimit: BootLimit?
    /// The picture's size in pixels, once the stream has said.
    private(set) var frameSize: CGSize?
    /// The stream shows a picture on this connection.
    private(set) var rendering = false
    /// Why the stream went away, while it is being brought back.
    private(set) var streamError: String?
    private(set) var retired = false

    private let service: any DeviceServing
    private let connector: DeviceStreamConnector
    private let keepsStreaming: Duration
    private let reconnectDelay: Duration

    /// `keepsStreaming` is how long a hidden pane keeps its stream, so switching back is instant.
    init(owner: String, service: any DeviceServing, keepsStreaming: Duration = .seconds(15),
         reconnectDelay: Duration = .seconds(1), connector: DeviceStreamConnector? = nil) {
        self.owner = deviceOwner(owner); self.service = service
        self.keepsStreaming = keepsStreaming; self.reconnectDelay = reconnectDelay
        self.connector = connector ?? { path, udid, sink, events in
            DeviceFrameConnection(path: path, udid: udid, sink: sink, events: events)
        }
    }

    // MARK: What the pane shows

    var availability: DeviceAvailability { state?.availability ?? .available }
    var blocker: DeviceAvailability.Blocker? { availability.blocker }
    var agentActive: Bool { state?.agentActive ?? false }
    /// The device shown: the one just picked until the backend answers, then the attached one.
    var device: DeviceDescriptor? {
        let attached = state?.attachedDevice
        guard let pending else { return attached }
        guard (state?.attachedDeviceUdid) == pending.supersedes else { return attached }
        return state?.devices.first { $0.udid == pending.device.udid } ?? pending.device
    }
    /// Booted first, then booting, then the rest; by name within each, so the list holds still as
    /// states change.
    var devices: [DeviceDescriptor] {
        let attached = state?.attachedDeviceUdid
        func rank(_ device: DeviceDescriptor) -> Int {
            device.udid == attached ? 0 : device.state == .booted ? 1 : device.state == .booting ? 2 : 3
        }
        return (state?.devices ?? []).sorted {
            rank($0) != rank($1) ? rank($0) < rank($1) : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    /// What the screen says while the attachment comes up (Synara `deviceAttachStatusLabel`).
    var attachStatus: String? {
        guard let device else { return nil }
        if let phase = state?.attachPhase { return phase.label }
        switch device.state {
        case .booting: return DeviceAttachPhase.booting.label
        case .shutdown: return pending != nil ? DeviceAttachPhase.booting.label : nil
        case .shuttingDown: return String(localized: "Shutting down…")
        case .booted: return pending != nil ? DeviceAttachPhase.connecting.label : nil
        }
    }
    /// The error to show over the screen: the backend's for the attachment, else the stream's.
    var error: String? { state?.lastError ?? streamError }

    // MARK: State

    /// Reads the owner's state afresh (it also lists devices booted elsewhere since).
    func load() {
        guard !retired else { return }
        Task { [weak self, service, owner] in
            do {
                let state = try await service.state(owner: owner)
                self?.receive(state)
                if self?.retired == false { self?.loadError = nil }
            } catch {
                guard let self, !self.retired else { return }
                if self.state == nil { self.loadError = error.localizedDescription }
            }
        }
    }

    /// A state the backend pushed or answered. Never an older one over a newer.
    func receive(_ state: OwnerDeviceState) {
        guard !retired, deviceOwner(state.owner) == owner else { return }
        if let current = self.state, current.version > state.version { return }
        self.state = state
        // Answered: the backend moved off the attachment the pick was made against, or it is on
        // the picked device with nothing left to wait for.
        if let pending, state.attachedDeviceUdid != pending.supersedes
            || (state.attachedDeviceUdid == pending.device.udid && state.attachPhase == nil) { self.pending = nil }
        if state.availability.blocker?.retryable == true { pollSetup() } else { setupPoll?.cancel(); setupPoll = nil }
        streamFollows()
    }

    /// An agent asked for the pane on `udid`. The backend has attached it unless the owner already
    /// watched another device, which stays: that one was the user's choice.
    func agentOpened(udid: String) {
        guard !retired else { return }
        load()
    }

    /// A Run on a simulator: the pane follows the device it runs on. The Run boots it, so this only
    /// attaches; the backend waits out the boot.
    func attach(udid: String) {
        guard !retired, !udid.isEmpty else { return }
        if let known = state?.devices.first(where: { $0.udid == udid }) { pick(known) }
        perform(failure: String(localized: "Could not open that simulator")) { model, service in
            do { model.receive(try await service.attach(owner: model.owner, udid: udid)) }
            catch { model.pending = nil; throw error }
        }
    }

    /// A pick in the device list: a booted device is attached, a shut-down one booted first.
    func select(_ device: DeviceDescriptor) {
        guard !retired, device.state == .booted || device.state == .shutdown else { return }
        pick(device)
        perform(failure: String(localized: "Could not open that simulator")) { model, service in
            do {
                if device.state == .shutdown, try await model.bootOrOfferSlots(device) == false { return }
                model.receive(try await service.attach(owner: model.owner, udid: device.udid))
            } catch { model.pending = nil; throw error }
        }
    }

    /// Shuts `candidate` down to make room for the device the boot limit turned away, then opens it.
    func freeSlot(shuttingDown candidate: DeviceDescriptor) {
        guard !retired, let limit = bootLimit else { return }
        bootLimit = nil
        if let requested = state?.devices.first(where: { $0.udid == limit.udid }) { pick(requested) }
        perform(failure: String(localized: "Could not free a simulator slot")) { model, service in
            do {
                try await service.shutdown(udid: candidate.udid)
                let device = DeviceDescriptor(udid: limit.udid, name: limit.name, runtime: "", state: .shutdown)
                if try await model.bootOrOfferSlots(device) == false { return }
                model.receive(try await service.attach(owner: model.owner, udid: limit.udid))
            } catch { model.pending = nil; throw error }
        }
    }

    func dismissBootLimit() { if !retired { bootLimit = nil } }

    /// Shows `device` until the backend answers, unless it is the one already attached: then there
    /// is no change of device to wait for, and nothing would ever clear it.
    private func pick(_ device: DeviceDescriptor) {
        guard device.udid != state?.attachedDeviceUdid else { pending = nil; return }
        pending = Pending(device: device, supersedes: state?.attachedDeviceUdid)
    }

    /// False when the boot limit turned it away, with the candidates offered.
    private func bootOrOfferSlots(_ device: DeviceDescriptor) async throws -> Bool {
        switch try await service.boot(udid: device.udid) {
        case .booted: return true
        case .bootLimitReached(let limit, let candidates):
            guard !retired else { return false }
            pending = nil
            bootLimit = BootLimit(limit: limit, candidates: candidates, udid: device.udid, name: device.name)
            return false
        }
    }

    func detach() {
        guard !retired else { return }
        pending = nil
        perform(failure: String(localized: "Could not detach the simulator")) { model, service in
            model.receive(try await service.detach(owner: model.owner))
        }
    }

    func shutDown() {
        guard !retired, let udid = device?.udid else { return }
        perform(failure: String(localized: "Could not shut down the simulator")) { model, service in
            try await service.shutdown(udid: udid)
            model.load()
        }
    }

    /// Attaches the shown device again: after an attach that timed out, or a stream that would not
    /// come back.
    func retry() {
        guard !retired else { return }
        streamError = nil
        if let udid = device?.udid ?? state?.attachedDeviceUdid { attach(udid: udid) } else { load() }
        disconnect()
        streamFollows()
    }

    private func perform(failure: String, _ work: @escaping @MainActor (SimulatorPaneModel, any DeviceServing) async throws -> Void) {
        actionsRunning += 1; actionError = nil
        Task { [weak self, service] in
            guard let self else { return }
            do { try await work(self, service) }
            catch { if !self.retired { self.actionError = "\(failure): \(error.localizedDescription)" } }
            if !self.retired { self.actionsRunning -= 1 }
        }
    }

    @ObservationIgnored private var setupPoll: Task<Void, Never>?
    /// Nothing reports setup progress (Xcode installed, its licence accepted, a runtime downloaded),
    /// so a pane on the checklist asks again every few seconds while it is on screen.
    private func pollSetup() {
        guard setupPoll == nil else { return }
        setupPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled, !self.retired else { return }
                if self.visible { self.load() }
            }
        }
    }

    // MARK: Video

    /// The view the video is drawn in, kept here rather than in the panel's view: the panel is taken
    /// down and put back as tabs and sessions change, and the picture should not go with it.
    var screen: DeviceScreenView { screenView ?? makeScreen() }
    @ObservationIgnored private var screenView: DeviceScreenView?
    private func makeScreen() -> DeviceScreenView {
        let view = DeviceScreenView()
        // Retired, it is only a blank view that sends nothing anywhere.
        if !retired { view.input = { [weak self] input in self?.handle(input) } }
        screenView = view
        return view
    }
    private var sink: any DeviceSampleSink { screen.renderer }

    /// The session is on screen. Set by the workspace, which knows.
    @ObservationIgnored var active = false { didSet { if oldValue != active { streamFollows() } } }
    /// The pane shows the Simulator. Set by its view as it comes and goes.
    @ObservationIgnored var shown = false { didSet { if oldValue != shown { streamFollows() } } }
    private var visible: Bool { active && shown }

    @ObservationIgnored private var connection: (any DeviceStreamConnecting)?
    /// The device the stream reads, or is being opened for.
    @ObservationIgnored private(set) var streamUdid: String?
    @ObservationIgnored private var streamGeneration = UUID()
    @ObservationIgnored private var opening: Task<Void, Never>?
    @ObservationIgnored private var lingering: Task<Void, Never>?
    @ObservationIgnored private var reconnects = 0

    /// What the stream should read: the shown device, while it is booted and the pane can run.
    private var streamTarget: String? {
        guard !retired, blocker == nil, let device, device.state == .booted,
              state?.attachedDeviceUdid == device.udid else { return nil }
        return device.udid
    }

    /// Brings the stream in line with what is shown. A hidden pane keeps its stream a while, so
    /// switching back is instant; a device that changed or went down is let go at once.
    private func streamFollows() {
        let target = streamTarget
        if streamUdid != nil, target != streamUdid {
            disconnect(clearing: true)
        }
        guard let target else { return }
        if visible {
            lingering?.cancel(); lingering = nil
            if streamUdid == nil { connect(target) }
        } else if streamUdid != nil, lingering == nil {
            lingering = Task { [weak self, keepsStreaming] in
                try? await Task.sleep(for: keepsStreaming)
                guard let self, !Task.isCancelled, !self.visible else { return }
                self.lingering = nil
                self.disconnect()
            }
        }
    }

    private func connect(_ udid: String) {
        let generation = UUID(); streamGeneration = generation
        streamUdid = udid; rendering = false
        opening = Task { [weak self, service, owner] in
            do {
                let path = try await service.frameSocket(owner: owner, udid: udid)
                guard let self, self.streamGeneration == generation, !self.retired else { return }
                let events = DeviceFrameConnection.Events(
                    dimensions: { [weak self] size in
                        guard let self, self.streamGeneration == generation else { return }
                        self.frameSize = size
                    },
                    firstFrame: { [weak self] in
                        guard let self, self.streamGeneration == generation else { return }
                        self.rendering = true; self.streamError = nil; self.reconnects = 0
                    },
                    ended: { [weak self] message in self?.streamEnded(generation, message) })
                let connection = self.connector(path, udid, self.sink, events)
                self.connection = connection
                connection.start()
            } catch {
                self?.streamEnded(generation, error.localizedDescription)
            }
        }
    }

    /// The socket closed under the pane: opened again while it is still wanted, a little later each
    /// time it fails in a row.
    private func streamEnded(_ generation: UUID, _ message: String?) {
        guard !retired, streamGeneration == generation else { return }
        connection = nil; opening = nil; streamUdid = nil; rendering = false
        reconnects += 1
        if let message, reconnects > 1 { streamError = message }
        let delay = reconnectDelay * min(reconnects, 5)
        let next = UUID(); streamGeneration = next
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !self.retired, self.streamGeneration == next else { return }
            self.streamFollows()
        }
    }

    /// The renderer lost sync: ask for a fresh keyframe.
    func requestKeyframe() { if !retired { connection?.requestKeyframe() } }

    private func disconnect(clearing: Bool = false) {
        streamGeneration = UUID()
        opening?.cancel(); opening = nil
        lingering?.cancel(); lingering = nil
        connection?.stop(); connection = nil
        streamUdid = nil; rendering = false
        if clearing { frameSize = nil; screenView?.renderer.flush(removingImage: true) }
    }

    // MARK: Input

    /// The user's input on the screen, in the order it happened: each waits for the one before it,
    /// so a fast typist's keys land in order.
    @ObservationIgnored private var inputTail: Task<Void, Never>?

    func handle(_ input: DeviceScreenView.Input) {
        guard !retired, let device, device.state == .booted else { return }
        let udid = device.udid
        switch input {
        case .press(let from, let to, let bounds, let durationMs):
            let frame = frameSize ?? device.pointSize ?? .zero
            let map = { (point: CGPoint, clamped: Bool) in
                DeviceInputMapping.devicePoint(point, frame: frame, bounds: bounds, pointSize: device.pointSize, clamped: clamped)
            }
            // A press must start on the picture; a drag may end past its edge, which is the edge.
            switch DeviceInputMapping.gesture(from: map(from, false), to: map(to, true), durationMs: durationMs) {
            case .tap(let point): send { try await $0.tap(udid: udid, at: point) }
            case .swipe(let start, let end, let duration): send { try await $0.swipe(udid: udid, from: start, to: end, durationMs: duration) }
            case nil: break
            }
        case .text(let text): send { try await $0.type(udid: udid, text: text) }
        case .key(let usage, let modifiers, let down): send { try await $0.key(udid: udid, usage: usage, modifiers: modifiers, down: down) }
        case .button(let button): press(button)
        }
    }

    func press(_ button: DeviceKeyboard.Button) {
        guard !retired, let udid = device?.udid, device?.state == .booted else { return }
        send { try await $0.press(udid: udid, button: button) }
    }

    private func send(_ work: @escaping @Sendable (any DeviceServing) async throws -> Void) {
        let previous = inputTail
        inputTail = Task { [weak self, service] in
            await previous?.value
            do { try await work(service) }
            catch { if let self, !self.retired { self.actionError = error.localizedDescription } }
        }
    }

    // MARK: Lifetime

    /// Terminal: the session's context went away, and its pane with it. The backend's attachment
    /// stays; it goes when the session does.
    func retire() {
        guard !retired else { return }
        disconnect(clearing: true)
        retired = true
        setupPoll?.cancel(); setupPoll = nil
        inputTail?.cancel(); inputTail = nil
        // Kept, blank and deaf, so a view that still asks for it is not handed a new one.
        screenView?.input = nil
        screenView?.removeFromSuperview()
        pending = nil; bootLimit = nil; actionsRunning = 0
    }
}

/// The device's screen: the video, aspect kept, and the user's clicks and keys on it. It takes the
/// keyboard only when clicked, so the terminal keeps it otherwise.
final class DeviceScreenView: NSView {
    enum Input: Equatable {
        /// A press from `from` to `to`, in the view's points with the origin top left.
        case press(from: CGPoint, to: CGPoint, bounds: CGSize, durationMs: Double)
        case text(String)
        case key(UInt16, [DeviceKeyboard.Modifier], down: Bool)
        case button(DeviceKeyboard.Button)
    }
    var input: ((Input) -> Void)?
    let display = AVSampleBufferDisplayLayer()
    var renderer: AVSampleBufferVideoRenderer { display.sampleBufferRenderer }
    private var pressStart: (point: CGPoint, time: TimeInterval)?
    /// Keys sent down, by the Mac's key code, so each goes up as the usage it went down as.
    private var held: [UInt16: (UInt16, [DeviceKeyboard.Modifier])] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        display.videoGravity = .resizeAspect
        layer?.addSublayer(display)
        setAccessibilityIdentifier("simulator-screen")
        setAccessibilityRole(.image)
        setAccessibilityLabel(String(localized: "Simulator screen"))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        display.frame = bounds
        CATransaction.commit()
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // The one way the screen takes the keyboard: being clicked.
        window?.makeFirstResponder(self)
        pressStart = (convert(event.locationInWindow, from: nil), event.timestamp)
    }
    override func mouseUp(with event: NSEvent) {
        guard let start = pressStart else { return }
        pressStart = nil
        let end = convert(event.locationInWindow, from: nil)
        input?(.press(from: start.point, to: end, bounds: bounds.size, durationMs: (event.timestamp - start.time) * 1000))
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, case .button(let button)? = keyboardInput(event) else {
            return super.performKeyEquivalent(with: event)
        }
        input?(.button(button))
        return true
    }

    override func keyDown(with event: NSEvent) {
        switch keyboardInput(event) {
        case .text(let text)?: input?(.text(text))
        case .key(let usage, let modifiers)?:
            // The device repeats a held key itself.
            guard !event.isARepeat else { return }
            held[event.keyCode] = (usage, modifiers)
            input?(.key(usage, modifiers, down: true))
        case .button(let button)?: input?(.button(button))
        case nil: super.keyDown(with: event)
        }
    }
    override func keyUp(with event: NSEvent) {
        guard let (usage, modifiers) = held.removeValue(forKey: event.keyCode) else { return super.keyUp(with: event) }
        input?(.key(usage, modifiers, down: false))
    }
    override func resignFirstResponder() -> Bool {
        // A key still down would stay down on the device.
        for (usage, modifiers) in held.values { input?(.key(usage, modifiers, down: false)) }
        held.removeAll()
        return super.resignFirstResponder()
    }

    private func keyboardInput(_ event: NSEvent) -> DeviceKeyboard.Input? {
        let flags = event.modifierFlags
        return DeviceKeyboard.input(keyCode: event.keyCode, characters: event.characters,
                                    charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                                    command: flags.contains(.command), shift: flags.contains(.shift),
                                    option: flags.contains(.option), control: flags.contains(.control))
    }
}
