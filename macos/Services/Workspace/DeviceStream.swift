import AVFoundation
import CoreMedia
import Foundation

// The Simulator pane's video: the backend streams a device as H.264 over a Unix socket per device
// (`POST /api/device/frames` names it), in the device helper's own records. This file reads them
// off the main actor and hands decodable samples to an `AVSampleBufferVideoRenderer`, which
// decodes them with VideoToolbox. The pure parts — the record framing, the envelope, Annex B and
// the keyframe gate — are Synara's (`frameTransport.ts`, `deviceFrame.ts`, `DevicePanel.logic.ts`),
// ported so the pane reads the stream exactly as Synara's pane reads it.

/// One device-frame envelope (`crates/cascade-backend/src/device/frame.rs`).
struct DeviceFrameHeader: Equatable, Sendable {
    let deviceID: String
    let sequence: UInt32
    let timestampMs: Double
    let keyframe: Bool
    let codecConfig: Bool
}

struct DeviceFrame: Equatable, Sendable {
    let header: DeviceFrameHeader
    /// An H.264 Annex B access unit, or the SPS and PPS of a codec-config record.
    let payload: Data
}

enum DeviceFrameEnvelope {
    static let magic: UInt16 = 0x5346
    static let version: UInt8 = 1
    static let keyframeFlag: UInt8 = 0b01
    static let codecConfigFlag: UInt8 = 0b10
    /// Bytes before the variable-length device id.
    static let fixedHeaderBytes = 17

    /// The envelope's frame, or nil for bytes that are not one.
    static func decode(_ bytes: Data) -> DeviceFrame? {
        let bytes = Data(bytes) // Indexed from zero, whatever slice it came from.
        guard bytes.count >= fixedHeaderBytes else { return nil }
        guard UInt16(bytes[0]) | UInt16(bytes[1]) << 8 == magic, bytes[2] == version else { return nil }
        let flags = bytes[3]
        let idLength = Int(bytes[16])
        let payloadOffset = fixedHeaderBytes + idLength
        guard idLength > 0, bytes.count >= payloadOffset,
              let id = String(data: bytes[fixedHeaderBytes..<payloadOffset], encoding: .utf8) else { return nil }
        let sequence = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[4 + $1]) << (8 * UInt32($1)) }
        let bits = (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[8 + $1]) << (8 * UInt64($1)) }
        let header = DeviceFrameHeader(deviceID: id, sequence: sequence, timestampMs: Double(bitPattern: bits),
                                       keyframe: flags & keyframeFlag != 0, codecConfig: flags & codecConfigFlag != 0)
        return DeviceFrame(header: header, payload: bytes.subdata(in: payloadOffset..<bytes.count))
    }

    /// The envelope for `frame`, as the backend writes it; for tests.
    static func encode(_ frame: DeviceFrame) -> Data {
        var bytes = Data()
        bytes.append(UInt8(magic & 0xff)); bytes.append(UInt8(magic >> 8))
        bytes.append(version)
        bytes.append((frame.header.keyframe ? keyframeFlag : 0) | (frame.header.codecConfig ? codecConfigFlag : 0))
        withUnsafeBytes(of: frame.header.sequence.littleEndian) { bytes.append(contentsOf: $0) }
        withUnsafeBytes(of: frame.header.timestampMs.bitPattern.littleEndian) { bytes.append(contentsOf: $0) }
        let id = Data(frame.header.deviceID.utf8)
        bytes.append(UInt8(id.count)); bytes.append(id)
        bytes.append(frame.payload)
        return bytes
    }
}

/// Whole records out of a byte stream: a `u32` little-endian length, then that many bytes. A
/// length past the limit means the framing is lost, and the connection is dropped rather than
/// trusting the next length read from the same bytes.
struct DeviceRecordParser {
    struct Desynced: Error, Equatable { let declared: Int }
    static let maxRecordBytes = 8 * 1024 * 1024
    private var pending = Data()

    mutating func push(_ chunk: Data) throws -> [Data] {
        pending.append(chunk)
        var records: [Data] = []
        var offset = pending.startIndex
        while pending.endIndex - offset >= 4 {
            let length = Int((0..<4).reduce(UInt32(0)) { $0 | UInt32(pending[offset + $1]) << (8 * UInt32($1)) })
            guard length <= Self.maxRecordBytes else { throw Desynced(declared: length) }
            guard pending.endIndex - offset - 4 >= length else { break }
            records.append(pending.subdata(in: (offset + 4)..<(offset + 4 + length)))
            offset += 4 + length
        }
        pending = pending.subdata(in: offset..<pending.endIndex)
        return records
    }

    static func record(_ payload: Data) -> Data {
        var bytes = Data()
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { bytes.append(contentsOf: $0) }
        bytes.append(payload)
        return bytes
    }
}

/// H.264 in Annex B (start codes) as the helper sends it, and in the length-prefixed form
/// (AVCC) a `CMSampleBuffer` carries.
enum AnnexB {
    /// The NAL units of an Annex B stream, without their start codes (three or four bytes).
    static func nalUnits(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var starts: [(code: Int, payload: Int)] = []
        var index = 0
        while index + 2 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0 {
                if bytes[index + 2] == 1 { starts.append((index, index + 3)); index += 3; continue }
                if index + 3 < bytes.count, bytes[index + 2] == 0, bytes[index + 3] == 1 {
                    starts.append((index, index + 4)); index += 4; continue
                }
            }
            index += 1
        }
        return starts.indices.compactMap { position in
            let end = position + 1 < starts.count ? starts[position + 1].code : bytes.count
            let start = starts[position].payload
            return end > start ? Data(bytes[start..<end]) : nil
        }
    }

    static func type(of unit: Data) -> UInt8 { unit.first.map { $0 & 0x1f } ?? 0 }

    static let sps: UInt8 = 7, pps: UInt8 = 8, accessUnitDelimiter: UInt8 = 9

    /// Each NAL unit behind a four-byte big-endian length. Parameter sets and delimiters are left
    /// out: they travel in the format description.
    static func avcc(_ data: Data) -> Data {
        var out = Data()
        for unit in nalUnits(data) where ![sps, pps, accessUnitDelimiter].contains(type(of: unit)) {
            withUnsafeBytes(of: UInt32(unit.count).bigEndian) { out.append(contentsOf: $0) }
            out.append(unit)
        }
        return out
    }

    /// The sequence and picture parameter sets in `data`, when it has both.
    static func parameterSets(_ data: Data) -> (sps: [Data], pps: [Data])? {
        let units = nalUnits(data)
        let sps = units.filter { type(of: $0) == Self.sps }, pps = units.filter { type(of: $0) == Self.pps }
        return sps.isEmpty || pps.isEmpty ? nil : (sps, pps)
    }
}

/// Synara's frame gate (`stepDeviceFrameGate`): a decoder needs the codec config before any
/// sample and a keyframe after each config or gap. The stream is lossy by design (a slow viewer's
/// backlog is dropped), so a gap re-arms the keyframe requirement rather than ending the stream.
struct DeviceFrameGate: Equatable {
    enum Phase: Equatable { case awaitingConfig, awaitingKeyframe, streaming }
    enum Action: Equatable { case configure, decode(keyframe: Bool), drop, ignore }
    private(set) var phase: Phase = .awaitingConfig
    private(set) var lastSequence: UInt32?

    /// Past this a "forward" jump is a stale frame from an earlier stream, not a burst of drops.
    static let maxPlausibleGap: UInt32 = 1_024

    /// What to do with a frame, and whether to ask the backend for a keyframe now rather than
    /// wait for the next one the encoder makes on its own.
    mutating func step(_ header: DeviceFrameHeader, expecting udid: String?) -> (action: Action, requestKeyframe: Bool) {
        guard let udid, header.deviceID == udid else { return (.ignore, false) }
        if header.codecConfig {
            // The helper sends a config just before every keyframe, its periodic ones included: an
            // in-order config mid-stream announces a keyframe already on its way.
            let announces = phase == .streaming && lastSequence.map { header.sequence &- $0 == 1 } == true
            let request = phase != .awaitingKeyframe && !announces
            phase = .awaitingKeyframe; lastSequence = header.sequence
            return (.configure, request)
        }
        if phase == .awaitingConfig { return (.drop, false) }
        if let last = lastSequence {
            let distance = header.sequence &- last
            if distance == 0 || distance > Self.maxPlausibleGap { return (.drop, false) }
            if distance > 1, !header.keyframe, phase == .streaming {
                phase = .awaitingKeyframe; lastSequence = header.sequence
                return (.drop, true)
            }
        }
        if phase == .awaitingKeyframe, !header.keyframe {
            lastSequence = header.sequence
            return (.drop, false)
        }
        phase = .streaming; lastSequence = header.sequence
        return (.decode(keyframe: header.keyframe), false)
    }

    /// The decoder lost its place (the renderer failed): wait for a keyframe under the same config.
    mutating func needKeyframe() { if phase == .streaming { phase = .awaitingKeyframe } }
    /// The config could not be read: nothing decodes until another one comes.
    mutating func needConfig() { phase = .awaitingConfig }
}

/// Builds what the renderer takes from the stream's bytes.
enum DeviceSampleFactory {
    static func formatDescription(sps: [Data], pps: [Data]) -> CMVideoFormatDescription? {
        let sets = sps + pps
        var format: CMVideoFormatDescription?
        let storage = sets.map { [UInt8]($0) }
        let status: OSStatus = withPointers(storage) { pointers in
            CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: storage.count, parameterSetPointers: pointers,
                parameterSetSizes: storage.map(\.count), nalUnitHeaderLength: 4, formatDescriptionOut: &format)
        }
        return status == noErr ? format : nil
    }

    private static func withPointers<R>(_ arrays: [[UInt8]], _ body: ([UnsafePointer<UInt8>]) -> R) -> R {
        func go(_ index: Int, _ pointers: [UnsafePointer<UInt8>]) -> R {
            if index == arrays.count { return body(pointers) }
            return arrays[index].withUnsafeBufferPointer { go(index + 1, pointers + [$0.baseAddress!]) }
        }
        return go(0, [])
    }

    /// The picture's size in pixels as it is shown, cropping applied.
    static func dimensions(_ format: CMVideoFormatDescription) -> CGSize {
        CMVideoFormatDescriptionGetPresentationDimensions(format, usePixelAspectRatio: true, useCleanAperture: true)
    }

    /// One access unit as a sample shown the moment it is decoded: the stream is live, so it has no
    /// clock to wait for.
    static func sample(_ payload: Data, keyframe: Bool, timestampMs: Double, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        let avcc = AnnexB.avcc(payload)
        guard !avcc.isEmpty else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: avcc.count, flags: 0, blockBufferOut: &block) == noErr,
              let block,
              avcc.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                                                   offsetIntoDestination: 0, dataLength: avcc.count) }) == noErr
        else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(value: Int64(exactly: timestampMs.rounded()) ?? 0, timescale: 1000),
                                        decodeTimeStamp: .invalid)
        var size = avcc.count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                        sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let entry = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(entry, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            if !keyframe {
                CFDictionarySetValue(entry, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }
        return sample
    }
}

/// Where decoded samples go: the pane's `AVSampleBufferVideoRenderer`, or a recorder in tests.
protocol DeviceSampleSink: AnyObject {
    /// Whether the decoder failed or was interrupted and must be flushed before it decodes again.
    var needsFlush: Bool { get }
    func flush(removingImage: Bool)
    func enqueue(_ sample: CMSampleBuffer)
}

extension AVSampleBufferVideoRenderer: DeviceSampleSink {
    var needsFlush: Bool { status == .failed || requiresFlushToResumeDecoding }
    func flush(removingImage: Bool) { flush(removingDisplayedImage: removingImage, completionHandler: nil) }
}

/// Turns records into samples for a sink, and says when to ask for a keyframe. One per
/// connection; it runs on the connection's reading thread.
final class DeviceFrameDecoder {
    struct Report: Equatable {
        var requestKeyframe = false
        /// The picture's size, the first time it is known and whenever it changes.
        var dimensions: CGSize?
        /// A sample was handed to the sink.
        var rendered = false
    }
    private let udid: String
    private let sink: any DeviceSampleSink
    private(set) var gate = DeviceFrameGate()
    private var format: CMVideoFormatDescription?
    private var dimensions: CGSize?

    init(udid: String, sink: any DeviceSampleSink) { self.udid = udid; self.sink = sink }

    func receive(_ record: Data) -> Report {
        var report = Report()
        guard let frame = DeviceFrameEnvelope.decode(record) else { return report }
        // A decoder that failed (or was interrupted, the Mac asleep) shows nothing more until it is
        // flushed and handed a keyframe.
        if sink.needsFlush, gate.phase == .streaming {
            sink.flush(removingImage: false)
            gate.needKeyframe()
            report.requestKeyframe = true
        }
        let (action, request) = gate.step(frame.header, expecting: udid)
        report.requestKeyframe = report.requestKeyframe || request
        switch action {
        case .configure:
            if let sets = AnnexB.parameterSets(frame.payload), let made = DeviceSampleFactory.formatDescription(sps: sets.sps, pps: sets.pps) {
                format = made
                let size = DeviceSampleFactory.dimensions(made)
                if size != dimensions { dimensions = size; report.dimensions = size }
            } else {
                report.requestKeyframe = true
            }
        case .decode(let keyframe):
            // A keyframe past a config that could not be read: wait for a config, and ask for one,
            // rather than drop every frame from here on.
            guard let format else {
                gate.needConfig()
                report.requestKeyframe = true
                break
            }
            if keyframe, sink.needsFlush { sink.flush(removingImage: false) }
            guard let sample = DeviceSampleFactory.sample(frame.payload, keyframe: keyframe,
                                                                       timestampMs: frame.header.timestampMs, format: format) else { break }
            sink.enqueue(sample)
            report.rendered = true
        case .drop, .ignore:
            break
        }
        return report
    }
}

/// One viewer's connection to a device's frame socket. It reads on a thread of its own, since a
/// socket read blocks, and reports to the main actor. Stopping it ends the read; after `stop`
/// returns it hands the sink nothing more.
final class DeviceFrameConnection: @unchecked Sendable {
    struct Events: Sendable {
        var dimensions: @MainActor @Sendable (CGSize) -> Void = { _ in }
        var firstFrame: @MainActor @Sendable () -> Void = {}
        /// The connection ended by itself (not by `stop`), with why when it was an error.
        var ended: @MainActor @Sendable (String?) -> Void = { _ in }
    }
    static let resyncLine = Data("{\"type\":\"device.frame.resync\"}\n".utf8)

    /// Asks for a keyframe without waiting: this runs under `lock`, which `stop` takes on the main
    /// actor, so a backend that stopped reading must cost a lost ask, never a blocked main thread.
    private static func sendResync(_ socket: Int32) {
        resyncLine.withUnsafeBytes { _ = Darwin.send(socket, $0.baseAddress, $0.count, MSG_DONTWAIT) }
    }

    private let path: String
    private let decoder: DeviceFrameDecoder
    private let events: Events
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var stopped = false

    init(path: String, udid: String, sink: any DeviceSampleSink, events: Events) {
        self.path = path; self.events = events
        decoder = DeviceFrameDecoder(udid: udid, sink: sink)
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "cascade.device-frames"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        stopped = true
        if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR) }
    }

    /// Asks the backend to rebuild the stream from a fresh keyframe.
    func requestKeyframe() {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, fd >= 0 else { return }
        Self.sendResync(fd)
    }

    private func run() {
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { return finish(String(cString: strerror(errno))) }
        var on: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(socket); return finish(String(localized: "The frame socket's path is too long."))
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes); raw[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(socket); return finish(message)
        }
        lock.lock()
        if stopped { lock.unlock(); Darwin.close(socket); return }
        fd = socket
        lock.unlock()

        var parser = DeviceRecordParser()
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        var failure: String?
        var rendered = false
        reading: while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(socket, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                failure = String(cString: strerror(errno)); break
            }
            let records: [Data]
            do { records = try parser.push(Data(buffer[0..<count])) }
            catch { failure = String(localized: "The simulator stream lost its framing."); break }
            for record in records {
                lock.lock()
                if stopped { lock.unlock(); break reading }
                let report = decoder.receive(record)
                if report.requestKeyframe { Self.sendResync(socket) }
                lock.unlock()
                if let size = report.dimensions { let events = events; Task { @MainActor in events.dimensions(size) } }
                if report.rendered, !rendered { rendered = true; let events = events; Task { @MainActor in events.firstFrame() } }
            }
        }
        lock.lock()
        let wasStopped = stopped
        fd = -1
        lock.unlock()
        Darwin.close(socket)
        if !wasStopped { finish(failure) }
    }

    private func finish(_ message: String?) {
        lock.lock(); let wasStopped = stopped; lock.unlock()
        guard !wasStopped else { return }
        let events = events
        Task { @MainActor in events.ended(message) }
    }
}

/// Where a click lands on the device, and how a press becomes a tap or a swipe: Synara's
/// `deviceContainRect`, `canvasPointToDevicePoint` and `resolveDevicePointerGesture`.
enum DeviceInputMapping {
    /// Below this movement, in device points, a press is a tap: a trackpad jitters a little.
    static let tapMovementThreshold: CGFloat = 8

    enum Gesture: Equatable {
        case tap(CGPoint)
        case swipe(from: CGPoint, to: CGPoint, durationMs: Int)
    }

    /// Where a picture of `frame` pixels lands when fitted, aspect kept, into `bounds`.
    static func containRect(frame: CGSize, bounds: CGSize) -> CGRect? {
        guard frame.width > 0, frame.height > 0, frame.width.isFinite, frame.height.isFinite,
              bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(bounds.width / frame.width, bounds.height / frame.height)
        let size = CGSize(width: frame.width * scale, height: frame.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// A point in the view (origin top left) as a device point, or nil in the letterbox bands: a
    /// click there is no tap, rather than one clamped onto the screen's edge. `clamped` takes a
    /// point outside onto the edge instead, for where a drag that left the picture ends.
    static func devicePoint(_ point: CGPoint, frame: CGSize, bounds: CGSize, pointSize: CGSize?, clamped: Bool = false) -> CGPoint? {
        guard let rect = containRect(frame: frame, bounds: bounds) else { return nil }
        var x = point.x - rect.minX, y = point.y - rect.minY
        if clamped, x.isFinite, y.isFinite { x = min(max(x, 0), rect.width); y = min(max(y, 0), rect.height) }
        guard x >= 0, y >= 0, x <= rect.width, y <= rect.height else { return nil }
        let points = pointSize.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil } ?? inferredPointSize(frame)
        return CGPoint(x: min(max((x / rect.width * points.width).rounded(), 0), points.width),
                       y: min(max((y / rect.height * points.height).rounded(), 0), points.height))
    }

    /// Synara `inferDeviceScaleFactor`, for a device whose geometry the backend has not reported:
    /// 3x phones are 1000–1400 pixels wide, iPads wider at 2x, 2x phones 640 and up.
    static func inferredPointSize(_ frame: CGSize) -> CGSize {
        let width = frame.width
        let scale: CGFloat = width >= 1000 && width <= 1400 ? 3 : width > 1400 ? 2 : width >= 640 ? 2 : 1
        return CGSize(width: (frame.width / scale).rounded(), height: (frame.height / scale).rounded())
    }

    static func gesture(from: CGPoint?, to: CGPoint?, durationMs: Double) -> Gesture? {
        guard let from else { return nil }
        guard let to else { return .tap(from) }
        if hypot(to.x - from.x, to.y - from.y) <= tapMovementThreshold { return .tap(to) }
        // A zero-length swipe is a flick of infinite speed, which the helper refuses: one frame's worth.
        return .swipe(from: from, to: to, durationMs: min(max(16, Int(durationMs.rounded())), 10_000))
    }
}

/// The keyboard, as the device's HID usages (page 0x07).
enum DeviceKeyboard {
    enum Modifier: String, Codable, Sendable { case command, shift, option, control, function }
    enum Button: String, Codable, Sendable, CaseIterable { case home, lock, volumeUp = "volume-up", volumeDown = "volume-down" }

    /// What a key press on the screen sends.
    enum Input: Equatable {
        /// Printable text, typed as the device's keyboard would.
        case text(String)
        /// One HID key, down and up as the Mac's key is.
        case key(UInt16, [Modifier])
        /// One of Simulator.app's hardware chords.
        case button(Button)
    }

    /// Mac virtual key codes of the keys that are not text, as HID usages.
    static let specialKeys: [UInt16: UInt16] = [
        36: 0x28, 76: 0x28, // Return, keypad Enter
        53: 0x29, // Escape
        51: 0x2a, // Delete (backspace)
        48: 0x2b, // Tab
        117: 0x4c, // Forward delete
        115: 0x4a, 119: 0x4d, 116: 0x4b, 121: 0x4e, // Home, End, Page Up, Page Down
        124: 0x4f, 123: 0x50, 125: 0x51, 126: 0x52, // Right, Left, Down, Up
    ]

    private static let punctuation: [Character: UInt16] = [
        " ": 0x2c, "-": 0x2d, "=": 0x2e, "[": 0x2f, "]": 0x30, "\\": 0x31, ";": 0x33, "'": 0x34,
        "`": 0x35, ",": 0x36, ".": 0x37, "/": 0x38,
    ]

    /// Synara `deviceHidUsageForKey`, for a character typed with a modifier held.
    static func usage(for character: Character) -> UInt16? {
        let lower = Character(character.lowercased())
        guard let scalar = lower.unicodeScalars.first, lower.unicodeScalars.count == 1 else { return nil }
        if ("a"..."z").contains(lower) { return 0x04 + UInt16(scalar.value - 97) }
        if lower == "0" { return 0x27 }
        if ("1"..."9").contains(lower) { return 0x1e + UInt16(scalar.value - 49) }
        return punctuation[lower]
    }

    /// What a key press means for the device, or nil when it is the app's: other ⌘ chords stay
    /// the menu's, so ⌘W still closes the tab.
    static func input(keyCode: UInt16, characters: String?, charactersIgnoringModifiers: String?,
                      command: Bool, shift: Bool, option: Bool, control: Bool) -> Input? {
        let bare = charactersIgnoringModifiers?.lowercased() ?? ""
        if command {
            guard !control else { return nil }
            // Simulator.app's: ⌘⇧H home, ⌘L lock, ⌘↑ and ⌘↓ volume.
            if shift { return bare == "h" ? .button(.home) : nil }
            if keyCode == 126 { return .button(.volumeUp) }
            if keyCode == 125 { return .button(.volumeDown) }
            return bare == "l" ? .button(.lock) : nil
        }
        var modifiers: [Modifier] = []
        if shift { modifiers.append(.shift) }
        if option { modifiers.append(.option) }
        if control { modifiers.append(.control) }
        if let usage = specialKeys[keyCode] { return .key(usage, modifiers) }
        if control, let character = bare.first, let usage = usage(for: character) { return .key(usage, modifiers) }
        // The backend types printable ASCII; anything else (an accented letter, a dead key) has no
        // keystroke to send.
        guard let text = characters, !text.isEmpty,
              text.unicodeScalars.allSatisfy({ (0x20...0x7e).contains($0.value) }) else { return nil }
        return .text(text)
    }
}
