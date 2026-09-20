import Darwin
import AppKit
import Foundation
import GhosttyTerminal
import Testing

private final class FailureMessages: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return values }
}

@Test func geometryContractsRejectUnknownOwnersAndInconsistentSnapshots() throws {
    let fields: [String: Any] = ["cols": 80, "rows": 24, "cellWidthPixels": 9, "cellHeightPixels": 18]
    func geometry(_ updates: [String: Any]) throws -> PtyGeometry {
        let data = try JSONSerialization.data(withJSONObject: fields.merging(updates) { _, new in new })
        return try JSONDecoder().decode(PtyGeometry.self, from: data)
    }
    try geometry([:]).validate()
    for updates in [["cols": 0], ["rows": 4097], ["cellWidthPixels": 0], ["cellHeightPixels": 2731], ["cellWidthPixels": Int(UInt32.max)]] {
        #expect(throws: PtyError.self) { try geometry(updates).validate() }
    }
    var header = PtySnapshot.Header(token: 1, size: 10, chunkBytes: PtySnapshot.chunkBytes,
        seq: 0, stateSeq: 0, cols: 80, rows: 24, revision: PtySnapshot.revision, geometry: try geometry([:]))
    try header.validate()
    header.geometry = try geometry(["cols": 81])
    #expect(throws: PtyError.self) { try header.validate() }
    let json = "{\"id\":\"x\",\"cwd\":\"/tmp\",\"title\":\"x\",\"paired\":false,\"pairKey\":\"x\",\"hasContext\":false,\"pid\":1,\"created\":0,\"stateResponseOwner\":\"daemon-state-v1\",\"geometryResponseOwner\":\"daemon-geometry-v1\"}"
    let info = try JSONDecoder().decode(PtyInfo.self, from: Data(json.utf8))
    #expect(throws: PtyError.self) { try info.validateStateResponseOwner() }
    var hello = PtyHello(protocol: 2, pid: 1, dataEncoding: "base64", acknowledgedInput: true)
    #expect(throws: PtyError.self) { try hello.validateGeometryResponseOwner() }
    hello.geometryResponseOwner = "future-owner"
    #expect(throws: PtyError.self) { try hello.validateGeometryResponseOwner() }
    hello.geometryResponseOwner = PtyHello.geometryResponseOwnerVersion
    try hello.validateGeometryResponseOwner()
}

@Test func incompleteReplayIsRejectedAndOldHelpersAreDetected() throws {
    func decode(_ fields: String) throws -> PtyAttachment {
        try JSONDecoder().decode(PtyAttachment.self, from: Data("{\"bytes\":\"aGlzdG9yeQ==\",\"seq\":9,\(fields)}".utf8))
    }
    try decode("\"live\":true,\"truncated\":false").validateReplay()
    #expect(throws: PtyError.self) { try decode("\"live\":true,\"truncated\":true").validateReplay() }
    #expect(throws: PtyError.self) { try decode("\"live\":true").validateReplay() }
    #expect(throws: PtyError.self) { try decode("\"live\":false,\"truncated\":false").validateReplay() }
}

@Test func legacyHelperCannotSilentlyDowngradeNativeTerminalBytes() throws {
    let hello = try JSONDecoder().decode(PtyHello.self, from: Data(#"{"protocol":2,"pid":123}"#.utf8))
    #expect(throws: PtyError.self) { try hello.validateByteTransport() }
}

@Test func onlyAbsentOrRefusedSocketsPermitDaemonStartup() {
    #expect(PtydHost.mayStartDaemon(after: PtyError.socket(ENOENT)))
    #expect(PtydHost.mayStartDaemon(after: PtyError.socket(ECONNREFUSED)))
    #expect(!PtydHost.mayStartDaemon(after: PtyError.socket(EACCES)))
    #expect(!PtydHost.mayStartDaemon(after: PtyError.timeout))
    #expect(!PtydHost.mayStartDaemon(after: PtyError.protocolMismatch(999)))
    #expect(!PtydHost.mayStartDaemon(after: PtyError.closed))
}

@Test func resizeOnlyFloodCannotGrowTheAttachmentBufferWithoutBound() {
    let messages = FailureMessages()
    let pipe = TerminalPipe(onError: messages.append, onExit: { _ in })
    let client = PtydClient(onEvent: { _ in })
    pipe.bind(client: client, id: "flood")
    defer { pipe.close() }
    for sequence in 1...16385 {
        pipe.receive(.init(ev: "resize", id: "flood", bytes: nil, seq: 0,
                           exitCode: nil, signal: nil, stateSeq: UInt64(sequence), cols: 80, rows: 24))
    }
    #expect(messages.all.count == 1)
    #expect(messages.all.first?.contains("event limit") == true)
}
