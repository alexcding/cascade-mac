import AVFoundation
import CoreMedia
import Foundation
import Testing
import VideoToolbox

// The Simulator pane: the frame stream's parsing, the input mapping, and the pane model against a
// scripted device service and stream connector.

// MARK: - Fixtures

private final class DeviceServiceFixture: DeviceServing, @unchecked Sendable {
    var states: [OwnerDeviceState] = []
    var attachAnswer: (String, String) -> OwnerDeviceState = { owner, udid in
        OwnerDeviceState(owner: owner, version: 1, attachedDeviceUdid: udid, attachPhase: .connecting)
    }
    var bootAnswers: [DeviceBootResult] = []
    var calls: [String] = []
    var socketPath = "/tmp/cascade-test.sock"
    /// Holds each input call until released, to check they stay in order.
    var inputDelay: Duration = .zero

    func state(owner: String) async throws -> OwnerDeviceState {
        calls.append("state \(owner)")
        return states.isEmpty ? OwnerDeviceState(owner: owner, version: 0) : states.removeFirst()
    }
    func boot(udid: String) async throws -> DeviceBootResult {
        calls.append("boot \(udid)")
        return bootAnswers.isEmpty ? .booted(DeviceDescriptor(udid: udid, name: udid, runtime: "iOS", state: .booted)) : bootAnswers.removeFirst()
    }
    func shutdown(udid: String) async throws { calls.append("shutdown \(udid)") }
    func attach(owner: String, udid: String) async throws -> OwnerDeviceState {
        calls.append("attach \(owner) \(udid)")
        return attachAnswer(owner, udid)
    }
    func detach(owner: String) async throws -> OwnerDeviceState {
        calls.append("detach \(owner)")
        return OwnerDeviceState(owner: owner, version: 9)
    }
    func tap(udid: String, at point: CGPoint) async throws {
        if inputDelay != .zero { try await Task.sleep(for: inputDelay) }
        calls.append("tap \(udid) \(Int(point.x)),\(Int(point.y))")
    }
    func swipe(udid: String, from: CGPoint, to: CGPoint, durationMs: Int) async throws {
        calls.append("swipe \(udid) \(Int(from.x)),\(Int(from.y))->\(Int(to.x)),\(Int(to.y)) \(durationMs)ms")
    }
    func touch(udid: String, phase: DeviceTouchPhase, at point: CGPoint) async throws {
        if inputDelay != .zero { try await Task.sleep(for: inputDelay) }
        calls.append("touch \(udid) \(phase.rawValue) \(Int(point.x)),\(Int(point.y))")
    }
    func type(udid: String, text: String) async throws { calls.append("type \(udid) \(text)") }
    func key(udid: String, usage: UInt16, modifiers: [DeviceKeyboard.Modifier], down: Bool) async throws {
        calls.append("key \(udid) \(usage) \(modifiers.map(\.rawValue).joined(separator: "+")) \(down ? "down" : "up")")
    }
    func press(udid: String, button: DeviceKeyboard.Button) async throws { calls.append("button \(udid) \(button.rawValue)") }
    func frameSocket(owner: String, udid: String) async throws -> String {
        calls.append("frames \(udid)")
        return socketPath
    }
}

/// A press released at `to` with no drag seen between, as a fast flick can be.
@MainActor private func press(_ model: SimulatorPaneModel, from: CGPoint, to: CGPoint, bounds: CGSize, durationMs: Double) {
    model.handle(.pointer(.down, at: from, bounds: bounds, time: 10))
    model.handle(.pointer(.up, at: to, bounds: bounds, time: 10 + durationMs / 1000))
}

@MainActor private final class StreamRecorder {
    final class Connection: DeviceStreamConnecting {
        let path: String, udid: String
        let events: DeviceFrameConnection.Events
        var started = false, stopped = false, resyncs = 0
        init(path: String, udid: String, events: DeviceFrameConnection.Events) { self.path = path; self.udid = udid; self.events = events }
        func start() { started = true }
        func stop() { stopped = true }
        func requestKeyframe() { resyncs += 1 }
    }
    var connections: [Connection] = []
    var connector: DeviceStreamConnector {
        { [unowned self] path, udid, _, events in
            let connection = Connection(path: path, udid: udid, events: events)
            connections.append(connection)
            return connection
        }
    }
    var live: [Connection] { connections.filter { $0.started && !$0.stopped } }
}

private final class SinkRecorder: DeviceSampleSink {
    var samples: [CMSampleBuffer] = []
    var flushes = 0
    var needsFlush = false
    func flush(removingImage: Bool) { flushes += 1; needsFlush = false }
    func enqueue(_ sample: CMSampleBuffer) { samples.append(sample) }
}

@MainActor private func eventually(_ condition: () -> Bool) async {
    for _ in 0..<300 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
}

private let phone = DeviceDescriptor(udid: "PHONE-1", name: "iPhone 17", runtime: "iOS 27.0", state: .booted, bootSource: "user",
                                     family: "phone", geometry: DeviceGeometry(pointWidth: 402, pointHeight: 874, scale: 3))
private let tablet = DeviceDescriptor(udid: "TABLET-1", name: "iPad Air", runtime: "iOS 27.0", state: .shutdown, family: "tablet")

private func header(_ sequence: UInt32, keyframe: Bool = false, config: Bool = false, udid: String = "U") -> DeviceFrameHeader {
    DeviceFrameHeader(deviceID: udid, sequence: sequence, timestampMs: 0, keyframe: keyframe, codecConfig: config)
}

// MARK: - The stream's bytes

@Test func aFrameEnvelopeRoundTripsAndRefusesWhatIsNotOne() throws {
    let frame = DeviceFrame(header: DeviceFrameHeader(deviceID: "ABCD-1234", sequence: 0xDEADBEEF, timestampMs: 1234.5,
                                                      keyframe: true, codecConfig: false),
                            payload: Data([0, 0, 0, 1, 0x65, 0xAA]))
    let bytes = DeviceFrameEnvelope.encode(frame)
    #expect(Array(bytes.prefix(4)) == [0x46, 0x53, 1, 0b01], "magic 0x5346 little-endian, version 1, keyframe flag")
    #expect(DeviceFrameEnvelope.decode(bytes) == frame)
    // Read from a slice that does not start at zero, as records come out of a buffer.
    let padded = Data([9, 9, 9]) + bytes
    #expect(DeviceFrameEnvelope.decode(padded[3...]) == frame)
    var badMagic = bytes; badMagic[0] = 0
    #expect(DeviceFrameEnvelope.decode(badMagic) == nil)
    var badVersion = bytes; badVersion[2] = 2
    #expect(DeviceFrameEnvelope.decode(badVersion) == nil)
    #expect(DeviceFrameEnvelope.decode(bytes.prefix(16)) == nil)
}

@Test func recordsAreCutFromChunksWhereverTheChunksBreak() throws {
    let first = DeviceRecordParser.record(Data("one".utf8)), second = DeviceRecordParser.record(Data("second".utf8))
    let stream = first + second
    for cut in 0...stream.count {
        var parser = DeviceRecordParser()
        let records = try parser.push(stream.prefix(cut)) + parser.push(stream.dropFirst(cut))
        #expect(records == [Data("one".utf8), Data("second".utf8)], "cut at \(cut)")
    }
    var parser = DeviceRecordParser()
    #expect(throws: DeviceRecordParser.Desynced.self) { try parser.push(Data([0xff, 0xff, 0xff, 0x7f])) }
}

@Test func annexBBecomesLengthPrefixedWithoutItsParameterSets() {
    let sps = Data([0x67, 0x42, 0x00, 0x1e]), pps = Data([0x68, 0xce, 0x3c, 0x80]), idr = Data([0x65, 0x88, 0x84, 0x00])
    let aud = Data([0x09, 0xf0])
    // Four-byte and three-byte start codes, as encoders mix them.
    let stream = Data([0, 0, 0, 1]) + aud + Data([0, 0, 0, 1]) + sps + Data([0, 0, 1]) + pps + Data([0, 0, 0, 1]) + idr
    #expect(AnnexB.nalUnits(stream) == [aud, sps, pps, idr])
    #expect(AnnexB.avcc(stream) == Data([0, 0, 0, 4]) + idr)
    let sets = AnnexB.parameterSets(stream)
    #expect(sets?.sps == [sps] && sets?.pps == [pps])
    #expect(AnnexB.parameterSets(Data([0, 0, 0, 1]) + idr) == nil)
}

@Test func theGateWaitsForConfigThenAKeyframeAndAsksAgainAfterAGap() {
    var gate = DeviceFrameGate()
    #expect(gate.step(header(1), expecting: "U") == (.drop, false), "nothing decodes before the codec config")
    #expect(gate.step(header(2, config: true), expecting: "U") == (.configure, true), "a config that announces nothing asks for a keyframe")
    #expect(gate.step(header(3), expecting: "U") == (.drop, false), "a delta before the keyframe")
    #expect(gate.step(header(4, keyframe: true), expecting: "U") == (.decode(keyframe: true), false))
    #expect(gate.step(header(5), expecting: "U") == (.decode(keyframe: false), false))
    #expect(gate.step(header(5), expecting: "U") == (.drop, false), "a duplicate")
    #expect(gate.step(header(8), expecting: "U") == (.drop, true), "frames were lost mid-picture: wait for a keyframe, and ask")
    #expect(gate.phase == .awaitingKeyframe)
    #expect(gate.step(header(9, keyframe: true), expecting: "U") == (.decode(keyframe: true), false))
    // The helper's periodic config right before its keyframe is in order: no second request.
    #expect(gate.step(header(10, config: true), expecting: "U") == (.configure, false))
    #expect(gate.step(header(11, keyframe: true), expecting: "U") == (.decode(keyframe: true), false))
    #expect(gate.step(header(5_000), expecting: "U") == (.drop, false), "a stale frame from an earlier stream")
    #expect(gate.step(header(12, udid: "OTHER"), expecting: "U") == (.ignore, false))
    // The sequence wraps at 2^32.
    var wrapping = DeviceFrameGate()
    _ = wrapping.step(header(UInt32.max - 1, config: true), expecting: "U")
    _ = wrapping.step(header(UInt32.max, keyframe: true), expecting: "U")
    #expect(wrapping.step(header(0), expecting: "U") == (.decode(keyframe: false), false))
}

/// Real H.264 from VideoToolbox, as the helper's encoder makes it: its parameter sets and one
/// keyframe, in Annex B.
private func encodedKeyframe(width: Int = 96, height: Int = 64) throws -> (config: Data, keyframe: Data) {
    var session: VTCompressionSession?
    #expect(VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
                                       encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                       outputCallback: nil, refcon: nil, compressionSessionOut: &session) == noErr)
    let encoder = try #require(session)
    VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    var pixels: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pixels)
    let buffer = try #require(pixels)
    CVPixelBufferLockBaseAddress(buffer, [])
    memset(CVPixelBufferGetBaseAddress(buffer), 0x80, CVPixelBufferGetDataSize(buffer))
    CVPixelBufferUnlockBaseAddress(buffer, [])
    nonisolated(unsafe) var output: CMSampleBuffer?
    let properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
    VTCompressionSessionEncodeFrame(encoder, imageBuffer: buffer, presentationTimeStamp: .zero, duration: .invalid,
                                    frameProperties: properties, infoFlagsOut: nil) { _, _, sample in output = sample }
    VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid)
    VTCompressionSessionInvalidate(encoder)
    let sample = try #require(output)
    let format = try #require(CMSampleBufferGetFormatDescription(sample))
    var count = 0
    CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                       parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
    var config = Data()
    for index in 0..<count {
        var pointer: UnsafePointer<UInt8>?, size = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                           parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
        config += Data([0, 0, 0, 1]) + Data(bytes: try #require(pointer), count: size)
    }
    // AVCC (four-byte lengths) back to Annex B.
    let block = try #require(CMSampleBufferGetDataBuffer(sample))
    var avcc = Data(count: CMBlockBufferGetDataLength(block))
    _ = avcc.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
    var keyframe = Data(), offset = 0
    while offset + 4 <= avcc.count {
        let length = Int(avcc[offset]) << 24 | Int(avcc[offset + 1]) << 16 | Int(avcc[offset + 2]) << 8 | Int(avcc[offset + 3])
        keyframe += Data([0, 0, 0, 1]) + avcc[(offset + 4)..<(offset + 4 + length)]
        offset += 4 + length
    }
    return (config, keyframe)
}

@Test func theDecoderTurnsRealH264RecordsIntoSamplesTheRendererTakes() throws {
    let (config, keyframe) = try encodedKeyframe()
    let sink = SinkRecorder()
    let decoder = DeviceFrameDecoder(udid: "U", sink: sink)
    func record(_ sequence: UInt32, _ payload: Data, keyframe: Bool = false, config: Bool = false) -> Data {
        DeviceFrameEnvelope.encode(DeviceFrame(header: header(sequence, keyframe: keyframe, config: config), payload: payload))
    }
    let configured = decoder.receive(record(1, config, config: true))
    #expect(configured.dimensions == CGSize(width: 96, height: 64))
    let shown = decoder.receive(record(2, keyframe, keyframe: true))
    #expect(shown.rendered && !shown.requestKeyframe)
    let sample = try #require(sink.samples.first)
    #expect(CMSampleBufferIsValid(sample) && CMSampleBufferGetNumSamples(sample) == 1)
    let attachments = try #require(CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]])
    #expect(attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] as? Bool == true)

    // The decoder failed: the next frame flushes it, waits for a keyframe, and asks for one.
    sink.needsFlush = true
    let failed = decoder.receive(record(3, keyframe))
    #expect(failed.requestKeyframe && !failed.rendered && sink.flushes == 1)
    #expect(decoder.receive(record(4, keyframe, keyframe: true)).rendered)

    // And a real renderer decodes it.
    let layer = AVSampleBufferDisplayLayer()
    let renderer = layer.sampleBufferRenderer
    let live = DeviceFrameDecoder(udid: "U", sink: renderer)
    _ = live.receive(record(1, config, config: true))
    #expect(live.receive(record(2, keyframe, keyframe: true)).rendered)
    #expect(renderer.status != .failed, "\(String(describing: renderer.error))")
}

// MARK: - Input

@Test func clicksMapToDevicePointsAndTheLetterboxIsNoTap() throws {
    // A 1206×2622 phone frame (402×874 points at 3x) in a 500×500 view: fitted by height.
    let frame = CGSize(width: 1206, height: 2622), bounds = CGSize(width: 500, height: 500), points = CGSize(width: 402, height: 874)
    let rect = try #require(DeviceInputMapping.containRect(frame: frame, bounds: bounds))
    #expect(abs(rect.height - 500) < 0.001 && abs(rect.width - 1206 * 500 / 2622) < 0.001)
    #expect(DeviceInputMapping.devicePoint(CGPoint(x: 250, y: 250), frame: frame, bounds: bounds, pointSize: points)
            == CGPoint(x: 201, y: 437), "the middle is the middle")
    #expect(DeviceInputMapping.devicePoint(CGPoint(x: rect.minX, y: 0), frame: frame, bounds: bounds, pointSize: points) == .zero)
    #expect(DeviceInputMapping.devicePoint(CGPoint(x: 10, y: 250), frame: frame, bounds: bounds, pointSize: points) == nil)
    #expect(DeviceInputMapping.containRect(frame: .zero, bounds: bounds) == nil)
    // No geometry yet: the scale is read off the frame's width.
    #expect(DeviceInputMapping.inferredPointSize(frame) == points)
    #expect(DeviceInputMapping.inferredPointSize(CGSize(width: 1640, height: 2360)) == CGSize(width: 820, height: 1180))
}

@Test func aShortPressIsATapAndALongerOneASwipe() {
    let start = CGPoint(x: 100, y: 100)
    #expect(DeviceInputMapping.gesture(from: start, to: CGPoint(x: 104, y: 105), durationMs: 80) == .tap(CGPoint(x: 104, y: 105)))
    #expect(DeviceInputMapping.gesture(from: start, to: CGPoint(x: 100, y: 400), durationMs: 2)
            == .swipe(from: start, to: CGPoint(x: 100, y: 400), durationMs: 16), "never a swipe of no time")
    #expect(DeviceInputMapping.gesture(from: start, to: nil, durationMs: 300) == .tap(start), "released in the letterbox")
    #expect(DeviceInputMapping.gesture(from: nil, to: start, durationMs: 300) == nil, "pressed in the letterbox")
}

@Test func keysBecomeTextHIDKeysOrHardwareButtons() {
    func input(_ code: UInt16, _ text: String, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) -> DeviceKeyboard.Input? {
        DeviceKeyboard.input(keyCode: code, characters: text, charactersIgnoringModifiers: text.lowercased(),
                             command: command, shift: shift, option: option, control: control)
    }
    #expect(input(0, "a") == .text("a"))
    #expect(input(0, "A", shift: true) == .text("A"))
    #expect(input(36, "\r") == .key(0x28, []))
    #expect(input(51, "\u{7f}") == .key(0x2a, []))
    #expect(input(123, "\u{F702}", shift: true) == .key(0x50, [.shift]))
    #expect(input(0, "\u{1}", control: true) == .key(0x04, [.control]) || input(0, "a", control: true) == .key(0x04, [.control]))
    #expect(input(4, "h", command: true, shift: true) == .button(.home))
    #expect(input(37, "l", command: true) == .button(.lock))
    #expect(input(126, "\u{F700}", command: true) == .button(.volumeUp))
    #expect(input(125, "\u{F701}", command: true) == .button(.volumeDown))
    #expect(input(13, "w", command: true) == nil, "⌘W stays the app's")
    #expect(input(14, "é", option: true) == nil, "nothing the device can type")
    #expect(DeviceKeyboard.usage(for: "1") == 0x1e && DeviceKeyboard.usage(for: "0") == 0x27 && DeviceKeyboard.usage(for: "/") == 0x38)
}

// MARK: - Events

@Test func deviceEventsDecodeBesideEventsWhoseStateIsAString() throws {
    let device = #"{"type":"device","owner":"/w/app","state":{"owner":"/w/app","version":7,"attachedDeviceUdid":"PHONE-1","attachPhase":"waiting-for-display","devices":[{"platform":"ios-simulator","udid":"PHONE-1","name":"iPhone 17","runtime":"iOS 27.0","state":"booted","bootSource":"cascade","family":"phone","geometry":{"pointWidth":402,"pointHeight":874,"scale":3}}],"agentActive":true,"availability":{"kind":"setup-required","steps":[{"id":"install-xcode","label":"Install Xcode","done":true},{"id":"build-device-helper","label":"Build the helper","done":false}]},"lastError":null}}"#
    let event = try JSONDecoder().decode(ServerEvent.self, from: Data(device.utf8))
    let state = try #require(event.deviceState)
    #expect(state.version == 7 && state.attachedDeviceUdid == "PHONE-1" && state.attachPhase == .waitingForDisplay && state.agentActive)
    #expect(state.attachedDevice?.pointSize == CGSize(width: 402, height: 874) && state.attachedDevice?.bootSource == "cascade")
    #expect(state.availability.blocker == nil, "only the helper is left to build, which picking a device does")
    let open = try JSONDecoder().decode(ServerEvent.self, from: Data(#"{"type":"device-open-pane","owner":"/w/app/","udid":"PHONE-1","reason":"agent-launch"}"#.utf8))
    #expect(open.owner.map(deviceOwner) == "/w/app" && open.udid == "PHONE-1" && open.reason == "agent-launch" && open.deviceState == nil)
    let setup = try JSONDecoder().decode(ServerEvent.self, from: Data(#"{"type":"worktree-setup","worktree":"/w","state":"running"}"#.utf8))
    #expect(setup.worktree == "/w" && setup.deviceState == nil)
    let boot = try JSONDecoder().decode(DeviceBootResult.self, from: Data(#"{"kind":"boot-limit-reached","limit":3,"cascadeBooted":[]}"#.utf8))
    #expect(boot == .bootLimitReached(limit: 3, cascadeBooted: []))
    #expect(deviceOwner(" /w/app// ") == "/w/app" && deviceOwner("/") == "/")
}

@Test func setupThatNeedsTheUserBlocksThePaneAndDegradedOnlyWarns() {
    let steps = [DeviceSetupStep(id: "install-xcode", label: "Install Xcode", done: false),
                 DeviceSetupStep(id: "build-device-helper", label: "Build", done: false)]
    #expect(DeviceAvailability.setupRequired(steps).blocker?.steps == steps)
    #expect(DeviceAvailability.helperUnavailable("no swiftc").blocker?.detail == "no swiftc")
    #expect(DeviceAvailability.unsupportedPlatform("linux").blocker?.retryable == false)
    let degraded = DeviceAvailability.degraded([DeviceCapabilityStatus(id: "accessibility", ok: false),
                                                DeviceCapabilityStatus(id: "hid", ok: true)], DeviceToolchain(xcodeVersion: "27.0"))
    #expect(degraded.blocker == nil)
    #expect(degraded.degradedNotice == "Accessibility inspection unavailable with Xcode 27.0.")
}

// MARK: - The model

@MainActor @Test func thePaneShowsTheNewestStateAndNeverAnOlderOne() async {
    let service = DeviceServiceFixture()
    service.states = [OwnerDeviceState(owner: "/w", version: 3, devices: [phone, tablet])]
    let model = SimulatorPaneModel(owner: "/w/", service: service, connector: StreamRecorder().connector)
    #expect(model.owner == "/w")
    model.load()
    await eventually { model.state != nil }
    #expect(model.state?.version == 3 && model.device == nil)
    #expect(model.devices.map(\.udid) == ["PHONE-1", "TABLET-1"], "running first")
    model.receive(OwnerDeviceState(owner: "/w", version: 2, attachedDeviceUdid: "PHONE-1", devices: [phone]))
    #expect(model.state?.version == 3, "an older push is dropped")
    model.receive(OwnerDeviceState(owner: "/other", version: 9, attachedDeviceUdid: "PHONE-1", devices: [phone]))
    #expect(model.state?.version == 3, "another owner's")
    model.receive(OwnerDeviceState(owner: "/w", version: 4, attachedDeviceUdid: "PHONE-1", attachPhase: .booting, devices: [phone], agentActive: true))
    #expect(model.device == phone && model.agentActive && model.attachStatus == "Starting up…")
}

@MainActor @Test func pickingAShutDownDeviceBootsItThenAttachesShowingItMeanwhile() async {
    let service = DeviceServiceFixture()
    service.states = [OwnerDeviceState(owner: "/w", version: 1, devices: [phone, tablet])]
    let model = SimulatorPaneModel(owner: "/w", service: service, connector: StreamRecorder().connector)
    model.load()
    await eventually { model.state != nil }
    model.select(tablet)
    #expect(model.device?.udid == "TABLET-1" && model.attachStatus == "Starting up…", "the pick shows at once")
    await eventually { !model.busy }
    #expect(service.calls.suffix(2) == ["boot TABLET-1", "attach /w TABLET-1"])
    #expect(model.pending == nil && model.state?.attachedDeviceUdid == "TABLET-1")
}

@MainActor @Test func theBootLimitOffersTheDevicesToShutDownAndThenOpensThePick() async {
    let service = DeviceServiceFixture()
    let running = DeviceDescriptor(udid: "OLD-1", name: "iPhone 15", runtime: "iOS 26", state: .booted, bootSource: "cascade")
    service.states = [OwnerDeviceState(owner: "/w", version: 1, devices: [phone, tablet, running])]
    service.bootAnswers = [.bootLimitReached(limit: 3, cascadeBooted: [running])]
    let model = SimulatorPaneModel(owner: "/w", service: service, connector: StreamRecorder().connector)
    model.load()
    await eventually { model.state != nil }
    model.select(tablet)
    await eventually { !model.busy }
    #expect(model.bootLimit == .init(limit: 3, candidates: [running], udid: "TABLET-1", name: "iPad Air"))
    #expect(model.pending == nil && model.device == nil, "a refusal, not a pick in progress")
    model.freeSlot(shuttingDown: running)
    await eventually { !model.busy }
    #expect(service.calls.suffix(3) == ["shutdown OLD-1", "boot TABLET-1", "attach /w TABLET-1"])
    #expect(model.bootLimit == nil && model.state?.attachedDeviceUdid == "TABLET-1")
}

@MainActor @Test func theStreamRunsWhileThePaneIsSeenAndLingersBrieflyWhenHidden() async {
    let service = DeviceServiceFixture()
    let recorder = StreamRecorder()
    let model = SimulatorPaneModel(owner: "/w", service: service, keepsStreaming: .milliseconds(60),
                                   reconnectDelay: .milliseconds(20), connector: recorder.connector)
    model.receive(OwnerDeviceState(owner: "/w", version: 1, attachedDeviceUdid: "PHONE-1", devices: [phone]))
    #expect(recorder.connections.isEmpty, "nobody is looking")
    model.active = true; model.shown = true
    await eventually { recorder.live.count == 1 }
    #expect(recorder.live.first?.path == service.socketPath && recorder.live.first?.udid == "PHONE-1")
    recorder.live.first?.events.dimensions(CGSize(width: 1206, height: 2622))
    recorder.live.first?.events.firstFrame()
    #expect(model.rendering && model.frameSize == CGSize(width: 1206, height: 2622))

    // Hidden, then back within the grace: the same stream.
    model.shown = false
    try? await Task.sleep(for: .milliseconds(20))
    model.shown = true
    try? await Task.sleep(for: .milliseconds(80))
    #expect(recorder.connections.count == 1 && recorder.live.count == 1)
    // Hidden for good: let go.
    model.active = false
    await eventually { recorder.live.isEmpty }
    #expect(recorder.connections.count == 1 && !model.rendering)

    // The socket closing under a visible pane opens it again.
    model.active = true
    await eventually { recorder.live.count == 1 }
    let dropped = recorder.live.first
    dropped?.stopped = true // Ended by itself: nobody stops it, but it reads nothing more.
    dropped?.events.ended("Connection reset")
    await eventually { recorder.live.count == 1 && recorder.connections.count == 3 }
    #expect(recorder.connections.count == 3)

    // Another device: the old stream goes at once, the new one comes.
    let other = DeviceDescriptor(udid: "PHONE-2", name: "iPhone Air", runtime: "iOS 27.0", state: .booted)
    model.receive(OwnerDeviceState(owner: "/w", version: 2, attachedDeviceUdid: "PHONE-2", devices: [phone, other]))
    await eventually { recorder.live.first?.udid == "PHONE-2" }
    #expect(recorder.live.map(\.udid) == ["PHONE-2"] && model.frameSize == nil)
    // Shut down: nothing to stream.
    model.receive(OwnerDeviceState(owner: "/w", version: 3, attachedDeviceUdid: nil, devices: [phone]))
    #expect(recorder.live.isEmpty)
}

@MainActor @Test func clicksAndKeysReachTheDeviceInPointsAndInOrder() async {
    let service = DeviceServiceFixture()
    service.inputDelay = .milliseconds(30)
    let model = SimulatorPaneModel(owner: "/w", service: service, connector: StreamRecorder().connector)
    model.receive(OwnerDeviceState(owner: "/w", version: 1, attachedDeviceUdid: "PHONE-1", devices: [phone]))
    // No frame yet: mapped by the device's geometry. A 402×874 view shows it point for point.
    let bounds = CGSize(width: 402, height: 874)
    press(model, from: CGPoint(x: 100, y: 200), to: CGPoint(x: 102, y: 201), bounds: bounds, durationMs: 90)
    model.handle(.text("hi"))
    model.handle(.key(0x28, [], down: true))
    model.handle(.key(0x28, [], down: false))
    press(model, from: CGPoint(x: 200, y: 800), to: CGPoint(x: 200, y: 300), bounds: bounds, durationMs: 250)
    model.handle(.button(.home))
    press(model, from: CGPoint(x: -5, y: 10), to: CGPoint(x: -5, y: 10), bounds: CGSize(width: 1000, height: 874), durationMs: 50)
    await eventually { service.calls.count == 6 }
    #expect(service.calls == ["tap PHONE-1 102,201", "type PHONE-1 hi", "key PHONE-1 40  down", "key PHONE-1 40  up",
                              "swipe PHONE-1 200,800->200,300 250ms", "button PHONE-1 home"],
            "the tap held back by its delay still comes first; a click in the letterbox is no tap")
}

@MainActor @Test func aRunOrAnAgentPointsThePaneAtItsDevice() async {
    let service = DeviceServiceFixture()
    let model = SimulatorPaneModel(owner: "/w", service: service, connector: StreamRecorder().connector)
    model.attach(udid: "PHONE-1")
    await eventually { !model.busy }
    #expect(service.calls == ["attach /w PHONE-1"] && model.state?.attachedDeviceUdid == "PHONE-1")
    service.states = [OwnerDeviceState(owner: "/w", version: 5, attachedDeviceUdid: "PHONE-1", devices: [phone], agentActive: true)]
    model.agentOpened(udid: "PHONE-1")
    await eventually { model.state?.version == 5 }
    #expect(model.agentActive)
    model.detach()
    await eventually { !model.busy }
    #expect(service.calls.last == "detach /w" && model.device == nil)
}

@MainActor @Test func aRetiredPaneDoesNothingMore() async {
    let service = DeviceServiceFixture()
    let recorder = StreamRecorder()
    let model = SimulatorPaneModel(owner: "/w", service: service, connector: recorder.connector)
    model.active = true; model.shown = true
    model.receive(OwnerDeviceState(owner: "/w", version: 1, attachedDeviceUdid: "PHONE-1", devices: [phone]))
    await eventually { recorder.live.count == 1 }
    let connection = recorder.live.first
    model.retire()
    #expect(connection?.stopped == true && model.retired)
    let calls = service.calls
    model.load(); model.select(phone); model.attach(udid: "PHONE-1"); model.detach(); model.shutDown(); model.retry()
    model.receive(OwnerDeviceState(owner: "/w", version: 2, attachedDeviceUdid: "PHONE-2", devices: [phone]))
    model.handle(.text("x")); model.press(.home)
    model.shown = false; model.shown = true; model.active = false; model.active = true
    connection?.events.ended("gone")
    try? await Task.sleep(for: .milliseconds(80))
    #expect(service.calls == calls && recorder.connections.count == 1 && model.state?.version == 1)
}

// MARK: - Review fixes

/// A second Run on the device already attached (or Try Again) changes no device: nothing may be
/// left waiting over the live picture.
@MainActor @Test func aRunOnTheDeviceAlreadyAttachedLeavesNoConnectingOverThePicture() async {
    let service = DeviceServiceFixture()
    var version: UInt64 = 1
    service.attachAnswer = { owner, udid in
        version += 1
        return OwnerDeviceState(owner: owner, version: version, attachedDeviceUdid: udid, devices: [phone])
    }
    let model = SimulatorPaneModel(owner: "/w", service: service, connector: StreamRecorder().connector)
    model.receive(OwnerDeviceState(owner: "/w", version: 1, attachedDeviceUdid: "PHONE-1", devices: [phone]))
    model.attach(udid: "PHONE-1")
    #expect(model.pending == nil && model.attachStatus == nil)
    await eventually { !model.busy }
    #expect(model.pending == nil && model.attachStatus == nil && model.state?.attachedDeviceUdid == "PHONE-1")
    model.retry()
    await eventually { !model.busy }
    #expect(model.attachStatus == nil)
    // A pick of another device that the backend answers on that device, settled: cleared too.
    let other = DeviceDescriptor(udid: "PHONE-2", name: "iPhone Air", runtime: "iOS 27.0", state: .booted)
    model.receive(OwnerDeviceState(owner: "/w", version: version, attachedDeviceUdid: "PHONE-1", devices: [phone, other]))
    model.select(other)
    #expect(model.pending?.device == other)
    await eventually { !model.busy }
    #expect(model.pending == nil && model.attachStatus == nil)
}

@MainActor @Test func aDragThatLeavesThePictureIsASwipeToItsEdge() async {
    let service = DeviceServiceFixture()
    let model = SimulatorPaneModel(owner: "/w", service: service, connector: StreamRecorder().connector)
    model.receive(OwnerDeviceState(owner: "/w", version: 1, attachedDeviceUdid: "PHONE-1", devices: [phone]))
    // 402×874 points in a 1000×874 view: the picture spans x 299…701.
    let bounds = CGSize(width: 1000, height: 874)
    press(model, from: CGPoint(x: 500, y: 400), to: CGPoint(x: 900, y: 1200), bounds: bounds, durationMs: 200)
    await eventually { !service.calls.isEmpty }
    #expect(service.calls == ["swipe PHONE-1 201,400->402,874 200ms"])
    #expect(DeviceInputMapping.devicePoint(CGPoint(x: 900, y: -40), frame: CGSize(width: 402, height: 874), bounds: bounds,
                                           pointSize: nil, clamped: true) == CGPoint(x: 402, y: 0))
}

@MainActor @Test func aDragHoldsTheFingerDownAndFollowsThePointer() async {
    let service = DeviceServiceFixture()
    service.inputDelay = .milliseconds(40)
    let model = SimulatorPaneModel(owner: "/w", service: service, connector: StreamRecorder().connector)
    model.receive(OwnerDeviceState(owner: "/w", version: 1, attachedDeviceUdid: "PHONE-1", devices: [phone]))
    let bounds = CGSize(width: 402, height: 874)
    model.handle(.pointer(.down, at: CGPoint(x: 200, y: 600), bounds: bounds, time: 1))
    // Inside the tap's jitter: nothing touches yet.
    model.handle(.pointer(.moved, at: CGPoint(x: 203, y: 597), bounds: bounds, time: 1.01))
    #expect(service.calls.isEmpty)
    // Past it: the finger goes down where the press began and moves; moves that pile up behind a
    // slow one are folded into the newest.
    model.handle(.pointer(.moved, at: CGPoint(x: 200, y: 560), bounds: bounds, time: 1.02))
    model.handle(.pointer(.moved, at: CGPoint(x: 200, y: 500), bounds: bounds, time: 1.03))
    model.handle(.pointer(.moved, at: CGPoint(x: 200, y: 450), bounds: bounds, time: 1.04))
    model.handle(.pointer(.up, at: CGPoint(x: 200, y: 440), bounds: bounds, time: 1.05))
    await eventually { service.calls.last?.contains(" up ") == true }
    #expect(service.calls == ["touch PHONE-1 down 200,600", "touch PHONE-1 move 200,450", "touch PHONE-1 up 200,440"])
}

@MainActor @Test func aDragsLeftoverMoveIsNotSentForTheNextOne() async {
    let service = DeviceServiceFixture()
    service.inputDelay = .milliseconds(40)
    let model = SimulatorPaneModel(owner: "/w", service: service, connector: StreamRecorder().connector)
    model.receive(OwnerDeviceState(owner: "/w", version: 1, attachedDeviceUdid: "PHONE-1", devices: [phone]))
    let bounds = CGSize(width: 402, height: 874)
    // Two drags back to back while the first's steps are still waiting to go.
    for (x, time) in [(CGFloat(100), 1.0), (CGFloat(300), 2.0)] {
        model.handle(.pointer(.down, at: CGPoint(x: x, y: 600), bounds: bounds, time: time))
        model.handle(.pointer(.moved, at: CGPoint(x: x, y: 500), bounds: bounds, time: time + 0.01))
        model.handle(.pointer(.up, at: CGPoint(x: x, y: 400), bounds: bounds, time: time + 0.02))
    }
    await eventually { service.calls.count >= 5 && service.calls.last == "touch PHONE-1 up 300,400" }
    #expect(service.calls == ["touch PHONE-1 down 100,600", "touch PHONE-1 up 100,400",
                              "touch PHONE-1 down 300,600", "touch PHONE-1 move 300,500", "touch PHONE-1 up 300,400"]
            || service.calls == ["touch PHONE-1 down 100,600", "touch PHONE-1 move 100,500", "touch PHONE-1 up 100,400",
                                 "touch PHONE-1 down 300,600", "touch PHONE-1 move 300,500", "touch PHONE-1 up 300,400"],
            "each drag's steps go to that drag, in order: \(service.calls)")
}

@MainActor @Test func aDragCutShortStillLiftsTheFinger() async {
    let service = DeviceServiceFixture()
    let model = SimulatorPaneModel(owner: "/w", service: service, connector: StreamRecorder().connector)
    model.receive(OwnerDeviceState(owner: "/w", version: 1, attachedDeviceUdid: "PHONE-1", devices: [phone]))
    let bounds = CGSize(width: 402, height: 874)
    model.handle(.pointer(.down, at: CGPoint(x: 200, y: 600), bounds: bounds, time: 1))
    model.handle(.pointer(.moved, at: CGPoint(x: 200, y: 500), bounds: bounds, time: 1.01))
    // The session goes away mid-drag: the finger is lifted where it was, not left down.
    model.retire()
    await eventually { service.calls.last?.contains(" up ") == true }
    #expect(service.calls.last == "touch PHONE-1 up 200,500")
}

@Test func aConfigThatCannotBeReadWaitsForAnotherAndAsks() throws {
    let (config, keyframe) = try encodedKeyframe()
    let sink = SinkRecorder()
    let decoder = DeviceFrameDecoder(udid: "U", sink: sink)
    func record(_ sequence: UInt32, _ payload: Data, keyframe: Bool = false, config: Bool = false, at time: Double = 0) -> Data {
        DeviceFrameEnvelope.encode(DeviceFrame(header: DeviceFrameHeader(deviceID: "U", sequence: sequence, timestampMs: time,
                                                                         keyframe: keyframe, codecConfig: config), payload: payload))
    }
    _ = decoder.receive(record(1, Data([0, 0, 0, 1, 0x67, 0x00]), config: true))
    let orphan = decoder.receive(record(2, keyframe, keyframe: true))
    #expect(orphan.requestKeyframe && !orphan.rendered && decoder.gate.phase == .awaitingConfig)
    _ = decoder.receive(record(3, config, config: true))
    // A damaged timestamp far past what a CMTime holds is no crash.
    #expect(decoder.receive(record(4, keyframe, keyframe: true, at: 1e300)).rendered)
    #expect(decoder.receive(record(5, keyframe, keyframe: true, at: -.infinity)).rendered)
}

@MainActor @Test func aRetiredPaneKeepsItsScreenAndAsksForNothing() async {
    let recorder = StreamRecorder()
    let model = SimulatorPaneModel(owner: "/w", service: DeviceServiceFixture(), connector: recorder.connector)
    let screen = model.screen
    model.active = true; model.shown = true
    model.receive(OwnerDeviceState(owner: "/w", version: 1, attachedDeviceUdid: "PHONE-1", devices: [phone]))
    await eventually { recorder.live.count == 1 }
    model.retire()
    model.requestKeyframe(); model.dismissBootLimit()
    #expect(model.screen === screen && screen.input == nil && recorder.connections.first?.resyncs == 0)
    let fresh = SimulatorPaneModel(owner: "/w", service: DeviceServiceFixture(), connector: recorder.connector)
    fresh.retire()
    #expect(fresh.screen.input == nil && fresh.screen === fresh.screen)
}

@Test func ownersResolveSymlinksAsTheBackendDoes() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("owner-\(UUID().uuidString)")
    let real = root.appendingPathComponent("real"), link = root.appendingPathComponent("link")
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    defer { try? FileManager.default.removeItem(at: root) }
    // The temporary folder is under /var, itself a link to /private/var: as `pwd -P` reports it.
    let resolved = deviceOwner(real.path)
    #expect(resolved.hasPrefix("/private/") && resolved.hasSuffix("/real"))
    #expect(deviceOwner(" \(link.path)/ ") == resolved)
    #expect(deviceOwner("/nowhere/at/all/") == "/nowhere/at/all")
}
