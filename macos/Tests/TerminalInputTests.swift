import Foundation
import Testing

private actor InputReceiver {
    private(set) var received: [Data] = []
    private var waiter: CheckedContinuation<Void, Error>?
    func send(_ data: Data) async throws {
        received.append(data)
        try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func finish(failing: Bool = false) {
        let value = waiter; waiter = nil
        if failing { value?.resume(throwing: PtyError.connection("queue full")) }
        else { value?.resume() }
    }
    func waitFor(_ count: Int) async throws {
        for _ in 0..<100 {
            if received.count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PtyError.timeout
    }
}
private final class InputErrors: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    func append(_ value: String) { lock.lock(); messages.append(value); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return messages }
}

@Test func terminalInputWaitsForAcknowledgementsAndStopsAfterPartialFailure() async throws {
    let receiver = InputReceiver(), errors = InputErrors()
    let queue = TerminalInputQueue(limit: 20, chunkSize: 2, send: { try await receiver.send($0) }, onError: errors.append)
    queue.enqueue(Data("abcdef".utf8))
    try await receiver.waitFor(1)
    #expect(await receiver.received == [Data("ab".utf8)])
    queue.enqueue(Data("gh".utf8))
    await receiver.finish()
    try await receiver.waitFor(2)
    #expect(await receiver.received == [Data("ab".utf8), Data("cd".utf8)])
    await receiver.finish(failing: true)
    for _ in 0..<100 where errors.all.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    queue.enqueue(Data("must not retry".utf8))
    #expect(errors.all.count == 1 && errors.all.first?.contains("Earlier input may have been sent") == true)
    #expect(await receiver.received.count == 2)
    queue.close()
}

@Test func terminalInputBoundsPendingAndInFlightBytesAndCloseStopsQueuedSuffix() async throws {
    for overflow in [true, false] {
        let receiver = InputReceiver(), errors = InputErrors()
        let queue = TerminalInputQueue(limit: 6, chunkSize: 2, send: { try await receiver.send($0) }, onError: errors.append)
        queue.enqueue(Data("abcd".utf8))
        try await receiver.waitFor(1)
        queue.enqueue(Data("ef".utf8)) // two in flight plus four pending fill the budget
        if overflow { queue.enqueue(Data("g".utf8)) } else { queue.close() }
        await receiver.finish()
        try await Task.sleep(for: .milliseconds(30))
        #expect(await receiver.received == [Data("ab".utf8)])
        #expect(errors.all.count == (overflow ? 1 : 0))
        queue.close()
    }
}

@Test func nativeInputRequiresAcknowledgingHelperAndDecodesWriteFailureEvents() throws {
    let decoder = JSONDecoder()
    let old = try decoder.decode(PtyHello.self, from: Data(#"{"protocol":2,"pid":123,"dataEncoding":"base64"}"#.utf8))
    #expect(throws: PtyError.self) { try old.validateInputAcknowledgements() }
    let current = try decoder.decode(PtyHello.self, from: Data(#"{"protocol":2,"pid":123,"dataEncoding":"base64","acknowledgedInput":true}"#.utf8))
    try current.validateInputAcknowledgements()
    let event = try decoder.decode(PtyEvent.self, from: Data(#"{"ev":"inputError","id":"pty1","message":"write failed"}"#.utf8))
    #expect(event.message == "write failed")
}

@Test func reconnectFreezeRequiresAnIdleAcknowledgedInputStream() async throws {
    let receiver = InputReceiver(), errors = InputErrors()
    let idle = TerminalInputQueue(send: { try await receiver.send($0) }, onError: errors.append)
    #expect(idle.freezeForReconnect())
    #expect(!idle.freezeForReconnect())
    idle.enqueue(Data("ignored".utf8))
    #expect(await receiver.received.isEmpty)
    let active = TerminalInputQueue(chunkSize: 2, send: { try await receiver.send($0) }, onError: errors.append)
    active.enqueue(Data("abcd".utf8))
    try await receiver.waitFor(1)
    #expect(!active.freezeForReconnect())
    await receiver.finish()
    try await Task.sleep(for: .milliseconds(30))
    #expect(await receiver.received == [Data("ab".utf8)])
    #expect(errors.all.isEmpty)
}

@Test func terminalStateResponseOwnershipRequiresBothHelperAndShellAgreement() throws {
    let decoder = JSONDecoder()
    for owner in ["", "future-owner"] {
        let hello = try decoder.decode(PtyHello.self, from: Data("{\"protocol\":2,\"pid\":123,\"stateResponseOwner\":\"\(owner)\"}".utf8))
        #expect(throws: PtyError.self) { try hello.validateStateResponseOwner() }
    }
    let current = try decoder.decode(PtyHello.self, from: Data(#"{"protocol":2,"pid":123,"stateResponseOwner":"daemon-state-v1"}"#.utf8))
    try current.validateStateResponseOwner()
    var info = PtyInfo(id: "original", cwd: "/tmp", title: "Shell", paired: false, pairKey: "session", hasContext: true, pid: 123, created: 1)
    #expect(throws: PtyError.self) { try info.validateStateResponseOwner() }
    info.stateResponseOwner = PtyHello.stateResponseOwnerVersion
    try info.validateStateResponseOwner()
}

@Test func nativeIdentityRequiresACreationProfileAndMatchingHelperCapability() throws {
    let decoder = JSONDecoder()
    let old = try decoder.decode(PtyHello.self, from: Data(#"{"protocol":2,"pid":123}"#.utf8))
    #expect(throws: PtyError.self) { try old.validateIdentityResponseOwner() }
    #expect(throws: PtyError.self) { try old.validateShellIntegration() }
    let current = try decoder.decode(PtyHello.self, from: Data(#"{"protocol":2,"pid":123,"identityResponseOwner":"daemon-identity-v1","shellIntegration":true}"#.utf8))
    try current.validateIdentityResponseOwner()
    try current.validateShellIntegration()
    var info = PtyInfo(id: "original", cwd: "/tmp", title: "Shell", paired: false, pairKey: "session", hasContext: true, pid: 123, created: 1)
    info.stateResponseOwner = PtyHello.identityResponseOwnerVersion
    #expect(throws: PtyError.self) { try info.validateStateResponseOwner() }
    for invalid in [PtyTerminalProfile(version: "bad\u{1B}version", terminfoDirectory: "/tmp"),
                    PtyTerminalProfile(version: "1.0", terminfoDirectory: "relative"),
                    PtyTerminalProfile(version: "1.0", terminfoDirectory: "/tmp", resourcesDirectory: "relative")] {
        info.terminalProfile = invalid
        #expect(throws: PtyError.self) { try info.validateStateResponseOwner() }
    }
    info.terminalProfile = PtyTerminalProfile(version: "1.0-test", terminfoDirectory: "/tmp/owned-terminfo")
    try info.validateStateResponseOwner()
}
