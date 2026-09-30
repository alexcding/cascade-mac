import Foundation
import Testing

private func block(_ type: TranscriptBlock.Kind = .text, text: String? = nil, name: String? = nil, summary: String? = nil,
                   command: String? = nil, path: String? = nil, output: String? = nil, kind: String? = nil) -> TranscriptBlock {
    TranscriptBlock(type: type, text: text, id: nil, name: name, summary: summary, command: command, path: path,
                    old: nil, new: nil, output: output, isError: nil, kind: kind)
}

private func turn(_ id: String, at timestamp: String? = nil, role: TranscriptTurn.Role = .assistant,
                  blocks: [TranscriptBlock] = [block(text: "hello")]) -> TranscriptTurn {
    TranscriptTurn(id: id, role: role, timestamp: timestamp, ended: nil, model: nil, blocks: blocks)
}

private func session(_ id: String = "s1") -> RemoteSession {
    RemoteSession(id: id, title: "Fix it", project: "Cascade", cli: "claude", state: .working, host: "mac", hostName: "Mac",
                  updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
}

@MainActor private func mirror(defaults: UserDefaults, idleSeconds: @escaping () -> TimeInterval = { 0 }) -> RemoteMirror {
    RemoteMirror(defaults: defaults, dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                 available: false, idleSeconds: idleSeconds, hostName: "Test Mac")
}

@Test func remoteTurnsKeepTheLastTurnsInOrderWithTheSession() {
    let all = (0..<(RemoteSchema.turnsPerSession + 15)).map { turn("t\($0)") }
    let mapped = RemoteTurnMapper.turns(all, session: "abc", host: "mac")
    #expect(mapped.count == RemoteSchema.turnsPerSession)
    #expect(mapped.map(\.id) == all.suffix(RemoteSchema.turnsPerSession).map(\.id))
    #expect(mapped.allSatisfy { $0.session == "abc" })
}

@Test func remoteTurnOrdersStrictlyIncreaseWithMissingTimestamps() {
    let turns = [
        turn("a", at: "2026-01-01T10:00:00Z"),
        turn("b"),
        turn("c"),
        turn("d", at: "2026-01-01T10:00:00Z"),
        turn("e", at: "2026-01-01T09:00:00Z"),
        turn("f"),
    ]
    let orders = RemoteTurnMapper.turns(turns, session: "s", host: "mac").map(\.order)
    #expect(orders.count == turns.count)
    #expect(zip(orders, orders.dropFirst()).allSatisfy { $0 < $1 })
}

@Test func remoteTextBlocksAreCutAndMarked() throws {
    let limit = RemoteTurnMapper.Limits().text
    let long = String(repeating: "x", count: limit + 500)
    let mapped = RemoteTurnMapper.turns([turn("t", blocks: [block(text: long), block(text: "short")])], session: "s", host: "mac")
    let blocks = try #require(mapped.first?.blocks)
    let cut = try #require(blocks[0].text)
    #expect(cut.hasSuffix("…"))
    #expect(cut.count == limit + 1)
    #expect(blocks[0].truncated == true)
    #expect(blocks[1].text == "short")
    #expect(blocks[1].truncated == nil)
}

@Test func remoteOversizedTurnFallsBackToTightLimitsAndDropsThinking() throws {
    // Each block is cut to the normal text limit, but eighty of them still outgrow a record.
    let long = String(repeating: "y", count: RemoteTurnMapper.Limits().text + 1_000)
    let source = turn("big", blocks: [block(.thinking, text: "pondering")] + (0..<80).map { _ in block(text: long) })
    let mapped = try #require(RemoteTurnMapper.turns([source], session: "s", host: "mac").first)
    let size = try RemoteCodec.encoder.encode(mapped).count
    #expect(size <= RemoteSchema.maxPayload)
    #expect(mapped.blocks.allSatisfy { $0.type != .thinking })
    #expect(mapped.blocks.count == 80)
    #expect(mapped.blocks.first?.truncated == true)
}

@Test func remoteTurnTooBigEvenCutDownDropsItsEarliestBlocks() throws {
    let long = String(repeating: "z", count: RemoteTurnMapper.Limits().text)
    let blocks = (0..<400).map { block(text: "\($0) " + long) }
    let mapped = try #require(RemoteTurnMapper.turns([turn("huge", blocks: blocks)], session: "s", host: "mac").first)
    #expect(try RemoteCodec.encoder.encode(mapped).count <= RemoteSchema.maxPayload)
    #expect(mapped.blocks.count < 400)
    #expect(mapped.blocks.last?.text?.hasPrefix("399 ") == true)
    #expect(mapped.blocks.first?.truncated == true)
}

@Test func remoteToolBlocksKeepTheirFieldsAndCutOutput() throws {
    let limit = RemoteTurnMapper.Limits().output
    let tool = block(.tool, name: "Bash", summary: "Run tests", command: "swift test", path: "/tmp/a",
                     output: String(repeating: "o", count: limit + 100), kind: "run")
    let mapped = RemoteTurnMapper.turns([turn("t", blocks: [tool])], session: "s", host: "mac")
    let result = try #require(mapped.first?.blocks.first)
    #expect(result.type == .tool)
    #expect(result.name == "Bash")
    #expect(result.summary == "Run tests")
    #expect(result.command == "swift test")
    #expect(result.path == "/tmp/a")
    #expect(result.kind == "run")
    #expect(result.output?.count == limit + 1)
    #expect(result.output?.hasSuffix("…") == true)
    #expect(result.truncated == true)
}

@Test func remoteTurnRecordNamesNameTheirSession() {
    let name = RemoteTurn.recordName(session: "sess", id: "t1")
    #expect(RemoteTurn.session(ofRecordName: name) == "sess")
    #expect(RemoteTurn.session(ofRecordName: "session:x") == nil)
    #expect(RemoteTurn.session(ofRecordName: "turn:onlyone") == nil)
}

@Test func remoteEntriesEncodeStablyAndDecodeOnlyTheirOwnType() throws {
    let value = session()
    let first = try RemoteCodec.entry(value)
    let second = try RemoteCodec.entry(value)
    #expect(first.payload == second.payload)
    #expect(first.decode(RemoteCommand.self) == nil)
    #expect(first.decode(RemoteSession.self) == value)
}

@MainActor @Test func remoteMirrorWithoutEntitlementPersistsEnabledButIsUnavailable() throws {
    let suite = "RemoteMirrorTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let mirror = mirror(defaults: defaults, idleSeconds: { 10_000 })
    #expect(!mirror.enabled)
    mirror.setEnabled(true)
    #expect(defaults.bool(forKey: RemoteMirror.enabledKey))
    #expect(mirror.enabled)
    guard case .unavailable = mirror.status else {
        Issue.record("expected unavailable, got \(mirror.status)")
        return
    }
    #expect(!mirror.holdsApprovals)
}

@MainActor @Test func remoteSettingsModelReportsTheMirrorsState() throws {
    let empty = RemoteSettingsViewModel(mirror: nil)
    #expect(!empty.available)
    #expect(!empty.enabled)
    #expect(!empty.statusText.isEmpty)

    let suite = "RemoteMirrorTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let mirror = mirror(defaults: defaults)
    let model = RemoteSettingsViewModel(mirror: mirror)
    model.setEnabled(true)
    guard case .unavailable(let reason) = mirror.status else {
        Issue.record("expected unavailable, got \(mirror.status)")
        return
    }
    #expect(model.enabled)
    #expect(model.statusText == reason)
}

@MainActor @Test func remoteMirrorKeepsOneHostIDPerMac() throws {
    let suite = "RemoteMirrorTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = mirror(defaults: defaults)
    let second = mirror(defaults: defaults)
    #expect(!first.hostID.isEmpty)
    #expect(first.hostID == second.hostID)
    #expect(defaults.string(forKey: RemoteMirror.hostIDKey) == first.hostID)
}

@Test func remoteEntriesCarryTheMacTheyBelongTo() throws {
    let command = RemoteCommand(id: "c1", session: "s1", host: "mac-b", action: .message, text: "hi",
                                device: "iPhone", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    let entry = try RemoteCodec.entry(command)
    #expect(entry.host == "mac-b")
    #expect(entry.type == .command)
    let turn = try #require(RemoteTurnMapper.turns([turn("t")], session: "s1", host: "mac-a").first)
    #expect(try RemoteCodec.entry(turn).host == "mac-a")
}
