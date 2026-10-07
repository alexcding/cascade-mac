import AppKit
import Foundation
import WebKit
import XCTest
@testable import Cascade

/// A chat from New Task's form against the real backend linked in this process and the real default
/// agent, shown on the real chat page in a web view, with `chat-thread` events routed to the page as
/// the app routes them (`AppViewModel.receiveChat`). The first turn's page is made again twice while
/// the turn runs, as a screen rebuilt mid-turn would be. It needs a signed-in agent CLI and the
/// network, so it runs only when asked, and it is an XCTest case so it runs without a test daemon:
/// `CASCADE_LIVE_CHAT=1 xcrun xctest -XCTest ChatLiveTests …/CascadeTests.xctest`
/// (`CASCADE_LIVE_CHAT_SHOTS=<folder>` keeps a picture of the page at each step).
final class ChatLiveTests: XCTestCase {
    @MainActor func testANewChatsRepliesShowOnItsPageAsTheyCome() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CASCADE_LIVE_CHAT"] == "1" else { throw XCTSkip("Set CASCADE_LIVE_CHAT=1 to run the live chat test.") }
        let live = LiveChat(shots: environment["CASCADE_LIVE_CHAT_SHOTS"].map { URL(fileURLWithPath: $0) })
        do { try await live.run() } catch { XCTFail("\(error)") }
        for failure in live.failures { XCTFail(failure) }
        await live.stop()
    }
}

@MainActor private final class LiveChat {
    let shots: URL?
    var failures: [String] = []
    private let directory = URL(fileURLWithPath: "/tmp/cclive-\(UUID().uuidString.prefix(6))", isDirectory: true)
    private var backend: EmbeddedBackend?
    private var service: APIChatService?
    private var consumer: Task<Void, Error>?
    private var threadID: String?
    private var context: ChatPageContext?
    private(set) var page: ChatPageModel?
    private var view: WKWebView?
    private(set) var pages = 0
    private(set) var routed = 0
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 760), styleMask: [.titled],
                                  backing: .buffered, defer: false)

    init(shots: URL?) {
        self.shots = shots
        if let shots { try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true) }
        ChatPageAssets.useBuiltPage()
    }

    func stop() async {
        page?.retire()
        window.orderOut(nil)
        consumer?.cancel()
        await backend?.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    func log(_ line: String) {
        print("[live-chat] \(line)")
        guard let shots else { return }
        let file = shots.appendingPathComponent("timings.txt")
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        try? (text + line + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    func run() async throws {
        let backend = EmbeddedBackend(dataDirectory: directory, packaged: false)
        self.backend = backend
        let api = try await backend.start()
        let service = APIChatService(api: api)
        self.service = service
        guard let stream = backend.eventStream() else { throw BackendError.operation("no event stream") }
        consumer = Task {
            try await stream.consume(from: api.baseURL, onConnect: {}, onEvent: { [weak self] event in
                guard event.type == "chat-thread", let id = event.threadId, let events = event.events, !events.isEmpty else { return }
                await self?.route(id, events)
            })
        }

        // New Task's Chat side: no project, the first usable agent, the first message typed.
        let form = NewChatViewModel(projectID: nil, projectName: nil, folder: "", service: service)
        await form.load()
        log("agent \(form.agent ?? "none"), model \(form.model ?? "none")")
        if form.agent != "claude" { failures.append("the default agent is \(form.agent ?? "none"), not claude") }
        let made = Made()
        form.onAction = { if case .created(let shell) = $0 { made.shell = shell } }
        form.prompt = "Reply with exactly the word PONG and nothing else."
        let sentFirst = Date()
        await form.start()
        guard let shell = made.shell else { throw BackendError.operation("the chat was not made: \(form.error ?? "")") }
        log("start returned after \(seconds(since: sentFirst))s")

        // The chat's screen, as the app makes it once the form gives way.
        threadID = shell.id
        context = ChatPageContext(threadId: shell.id, projectId: shell.projectId, cwd: shell.cwd, projectName: "Chat", appearance: .light)
        window.orderBack(nil)
        openPage()

        for _ in 0..<200 {
            if await pageLines().contains(where: { $0.contains("Reply with exactly") }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        log("first message on the page after \(seconds(since: sentFirst))s")
        await shot("1-first-message")

        // The page made again twice while the turn runs.
        log("making the page again at \(seconds(since: sentFirst))s; backend has PONG: \(await backendHas("PONG"))")
        openPage()
        try await Task.sleep(for: .milliseconds(400))
        log("making the page again at \(seconds(since: sentFirst))s; backend has PONG: \(await backendHas("PONG"))")
        openPage()

        let first = await waitForReply("PONG", since: sentFirst)
        await shot(first.page == nil ? "2-pong-timeout" : "2-pong")
        log("PONG: backend \(first.backend.map { "\($0)s" } ?? "never"), page \(first.page.map { "\($0)s" } ?? "NEVER"); pages made \(pages); chat-thread events routed \(routed)")
        log("where PONG is drawn: \(await drawn("PONG"))")
        if first.page == nil {
            log("page text at timeout:\n\(await pageLines().joined(separator: "\n"))")
            failures.append("PONG never showed on the page")
        }

        // The second message, as the page's composer sends it, on the page now up.
        let sentSecond = Date()
        try await service.startTurn(threadID: shell.id, text: "Now reply with exactly PING.",
                                    provider: shell.modelSelection?.provider ?? "claudeAgent", model: shell.modelSelection?.model ?? "")
        let second = await waitForReply("PING", since: sentSecond)
        await shot(second.page == nil ? "3-ping-timeout" : "3-ping")
        log("PING: backend \(second.backend.map { "\($0)s" } ?? "never"), page \(second.page.map { "\($0)s" } ?? "NEVER"); chat-thread events routed \(routed)")
        log("where PING is drawn: \(await drawn("PING"))")
        if second.page == nil {
            log("page text at timeout:\n\(await pageLines().joined(separator: "\n"))")
            failures.append("PING never showed on the page")
        }
    }

    /// `AppViewModel.receiveChat`: a thread's events to the page showing it.
    private func route(_ id: String, _ events: [JSONValue]) {
        guard id == threadID else { return }
        routed += events.count
        page?.receiveThreadEvents(events)
    }

    /// A page made for the chat in the place of the one before, as a screen made again would be.
    private func openPage() {
        guard let context, let service else { return }
        page?.retire()
        let page = ChatPageModel(context: context, backend: ChatServiceBackend(service: { service }))
        self.page = page
        view = page.webView
        if let view {
            // A locked session's window counts as occluded, and WebKit then holds back the page's
            // animation frames, which the conversation's list lays itself out in.
            let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
            if let method = class_getInstanceMethod(type(of: view), selector) {
                typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
                unsafeBitCast(method_getImplementation(method), to: Setter.self)(view, selector, false)
            }
            window.contentView = view
        }
        pages += 1
    }

    private func pageLines() async -> [String] {
        let text = (try? await view?.evaluateJavaScript("document.body ? document.body.innerText : ''") as? String) ?? ""
        return text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func backendHas(_ word: String) async -> Bool {
        guard let service, let threadID,
              let snapshot = try? await service.rpc("orchestration.getThreadDetailSnapshot", params: ["threadId": .string(threadID)]),
              let messages = snapshot["thread"]?["messages"]?.array else { return false }
        return messages.contains { $0["role"]?.string == "assistant" && ($0["text"]?.string ?? "").contains(word) }
    }

    private func shot(_ name: String) async {
        guard let shots, let image = try? await view?.takeSnapshot(configuration: nil), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: shots.appendingPathComponent(name + ".png"))
    }

    /// Where the word's element is, and every ancestor that hides or moves it.
    private func drawn(_ word: String) async -> String {
        let script = """
            (() => { const els = [...document.querySelectorAll('*')].filter(e => e.childElementCount === 0 && e.textContent.trim() === '\(word)');
              return JSON.stringify({ viewport: [innerWidth, innerHeight], found: els.map(e => { const r = e.getBoundingClientRect();
                const odd = []; for (let n = e; n; n = n.parentElement) { const c = getComputedStyle(n);
                  if (c.opacity !== '1' || c.visibility !== 'visible' || c.transform !== 'none' || c.display === 'none')
                    odd.push(n.tagName + ' op=' + c.opacity + ' vis=' + c.visibility + ' tf=' + c.transform); }
                return { rect: [Math.round(r.x), Math.round(r.y), Math.round(r.width), Math.round(r.height)], odd }; }) }); })()
            """
        return (try? await view?.evaluateJavaScript(script) as? String) ?? "?"
    }

    /// Waits for a line on the page that is the word itself, and notes when the backend had it.
    private func waitForReply(_ word: String, since sent: Date) async -> (page: Double?, backend: Double?) {
        var backendAt: Double?
        while Date().timeIntervalSince(sent) < 90 {
            if backendAt == nil, await backendHas(word) { backendAt = seconds(since: sent) }
            let lines = await pageLines()
            if lines.contains(word) || lines.contains(word + ".") { return (seconds(since: sent), backendAt ?? seconds(since: sent)) }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return (nil, backendAt)
    }
}

@MainActor private final class Made { var shell: ChatThreadShell? }

private func seconds(since start: Date) -> Double { (Date().timeIntervalSince(start) * 10).rounded() / 10 }
