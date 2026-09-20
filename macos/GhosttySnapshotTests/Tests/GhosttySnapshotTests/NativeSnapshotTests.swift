import AppKit
import Foundation
import GhosttyKit
@testable import GhosttyTerminal
import Testing

private final class Writes: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ bytes: Data) { lock.lock(); data.append(bytes); lock.unlock() }
    var bytes: Data { lock.lock(); defer { lock.unlock() }; return data }
}

private final class Sizes: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [InMemoryTerminalViewport] = []
    func append(_ size: InMemoryTerminalViewport) { lock.lock(); values.append(size); lock.unlock() }
    var all: [InMemoryTerminalViewport] { lock.lock(); defer { lock.unlock() }; return values }
}

@MainActor
private final class Metadata: TerminalSurfaceTitleDelegate, TerminalSurfacePwdDelegate {
    var titles: [String] = []
    var directories: [String] = []
    var onTitle: (() -> Void)?
    func terminalDidChangeTitle(_ title: String) { titles.append(title); onTitle?() }
    func terminalDidChangeWorkingDirectory(_ path: String) { directories.append(path) }
}

@MainActor
private final class SurfaceHarness {
    let writes = Writes()
    let session: InMemoryTerminalSession
    let coordinator = TerminalSurfaceCoordinator()
    let metadata = Metadata()
    private let view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))

    init(controller: TerminalController = TerminalController(), resize: @escaping @Sendable (InMemoryTerminalViewport) -> Void = { _ in }) {
        let writes = self.writes
        session = InMemoryTerminalSession(write: { writes.append($0) }, resize: resize)
        view.wantsLayer = true
        coordinator.delegate = metadata
        coordinator.isAttached = { true }
        coordinator.scaleFactor = { 1 }
        coordinator.viewSize = { (800, 500) }
        coordinator.platformSetup = { [view] config in
            config.platform_tag = GHOSTTY_PLATFORM_MACOS
            config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
                nsview: Unmanaged.passUnretained(view).toOpaque()))
        }
        coordinator.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        coordinator.controller = controller
        precondition(coordinator.surface != nil)
    }
    func close() { coordinator.freeSurface() }
    func feed(_ bytes: Data) { session.receive(bytes); session.waitForPendingOutput() }
    var text: String { session.readViewportText() ?? "" }

    func snapshot(_ input: Data, extraColumn: Bool = false, includePixels: Bool = false, cellPixels: (UInt32, UInt32)? = nil) throws -> Data {
        let size = try #require(coordinator.surface?.size())
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let process = Process()
        process.executableURL = root.appendingPathComponent("crates/craft-vt/target/debug/examples/snapshot")
        process.arguments = [String(Int(size.columns) + (extraColumn ? 1 : 0)), String(size.rows)]
        if includePixels || cellPixels != nil {
            process.arguments?.append(contentsOf: [String(cellPixels?.0 ?? size.cellWidthPixels), String(cellPixels?.1 ?? size.cellHeightPixels)])
        }
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        try stdin.fileHandleForWriting.write(contentsOf: input)
        try stdin.fileHandleForWriting.close()
        let result = try stdout.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        return result
    }
}

@Suite(.serialized)
@MainActor
struct NativeSnapshotTests {
    @Test func geometryCallbacksIncludeMeasuredCellsAndTrackBackingScaleChanges() async throws {
        let sizes = Sizes()
        let harness = SurfaceHarness(resize: { sizes.append($0) })
        defer { harness.close() }
        try #require(harness.session.enableGeometryCallbacks())
        for _ in 0..<100 {
            if sizes.all.last?.cellWidthPixels ?? 0 > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let initial = try #require(sizes.all.last)
        #expect(initial.cellWidthPixels > 0 && initial.cellHeightPixels > 0)
        let count = sizes.all.count
        harness.coordinator.scaleFactor = { 2 }
        harness.coordinator.synchronizeMetrics()
        for _ in 0..<100 {
            if sizes.all.last?.cellWidthPixels ?? 0 > initial.cellWidthPixels { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let changed = try #require(sizes.all.last)
        let surface = try #require(harness.coordinator.surface?.size())
        #expect(changed.columns == surface.columns && changed.rows == surface.rows)
        // Font rasterization rounds differently at each backing scale; the
        // callback must carry measured cells, not multiply old metrics by two.
        #expect(changed.cellWidthPixels > initial.cellWidthPixels)
        #expect(changed.cellHeightPixels > initial.cellHeightPixels)
        #expect(changed.cellWidthPixels == surface.cellWidthPixels && changed.cellHeightPixels == surface.cellHeightPixels)
        #expect(sizes.all.count > count)
        #expect(sizes.all.dropFirst(count).allSatisfy { $0.cellWidthPixels > 0 && $0.cellHeightPixels > 0 })
        let paddingWidth = surface.widthPixels - changed.widthPixels
        let paddingHeight = surface.heightPixels - changed.heightPixels
        let width = Double(UInt32(changed.columns) * changed.cellWidthPixels + paddingWidth) / 2
        let height = Double(UInt32(changed.rows) * changed.cellHeightPixels + paddingHeight) / 2
        harness.coordinator.viewSize = { (width, height) }
        harness.coordinator.synchronizeMetrics()
        for _ in 0..<100 {
            if sizes.all.last?.widthPixels == UInt32(changed.columns) * changed.cellWidthPixels { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let aligned = try #require(sizes.all.last)
        harness.coordinator.viewSize = { (width + 0.5, height) } // one physical pixel, same grid
        harness.coordinator.synchronizeMetrics()
        for _ in 0..<100 {
            if sizes.all.last?.widthPixels == aligned.widthPixels + 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let subcell = try #require(sizes.all.last)
        #expect(subcell.columns == aligned.columns && subcell.rows == aligned.rows)
        #expect(subcell.cellWidthPixels == aligned.cellWidthPixels && subcell.cellHeightPixels == aligned.cellHeightPixels)
        #expect(subcell.widthPixels == aligned.widthPixels + 1)
    }

    @Test func daemonGeometrySuppressesSizeRepliesButPreservesTitleAndNativeInput() async throws {
        let harness = SurfaceHarness(controller: TerminalController { $0.withCustom("title-report", "true") })
        defer { harness.close() }
        #expect(!harness.session.enableHostGeometryResponses())
        try #require(harness.session.restoreSnapshot(try harness.snapshot(Data("\u{1B}[?2048h\u{1B}[16".utf8), includePixels: true)))
        try #require(harness.session.enableHostGeometryResponses())
        #expect(!harness.session.enableHostIdentityResponses()) // cannot downgrade ownership
        let surface = try #require(harness.coordinator.surface)
        let size = try #require(surface.size())
        #expect(!harness.session.applyHostGridSize(columns: size.columns, rows: size.rows))
        #expect(!harness.session.applyHostGeometry(columns: size.columns, rows: size.rows, cellWidthPixels: 0, cellHeightPixels: 18))
        #expect(!harness.session.applyHostGeometry(columns: size.columns, rows: size.rows, cellWidthPixels: .max, cellHeightPixels: 18))
        try #require(harness.session.applyHostGeometry(columns: size.columns + 3, rows: size.rows + 2,
            cellWidthPixels: size.cellWidthPixels, cellHeightPixels: size.cellHeightPixels))
        try #require(harness.session.applyHostGeometry(columns: size.columns + 3, rows: size.rows + 2,
            cellWidthPixels: size.cellWidthPixels * 2, cellHeightPixels: size.cellHeightPixels * 2))
        surface.setSize(width: size.widthPixels + 100, height: size.heightPixels + 100)
        // Complete the split query and keep native title reporting active.
        harness.feed(Data("t\u{1B}]2;Native title\u{07}\u{1B}[21t".utf8))
        let title = Data("\u{1B}]lNative title\u{1B}\\".utf8)
        for _ in 0..<100 {
            _ = harness.session.flushSnapshotMetadataCallbacks()
            if harness.writes.bytes.count >= title.count { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(harness.writes.bytes == title)
        harness.feed(Data("\u{1B}[14t\u{1B}[16t\u{1B}[18t\u{1B}[?2048l\u{1B}[?2048h\u{1B}[c\u{1B}[6n\u{1B}[?5522$p".utf8))
        let clipboard = Data("\u{1B}[?5522;2$y".utf8)
        for _ in 0..<100 {
            if harness.writes.bytes.count >= title.count + clipboard.count { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(harness.writes.bytes == title + clipboard)
        harness.feed(Data("\u{1B}c\u{1B}[14t\u{1B}[16t\u{1B}[18t\u{1B}[?2048h".utf8))
        try #require(surface.paste(text: "USER_INPUT"))
        let expected = title + clipboard + Data("USER_INPUT".utf8)
        for _ in 0..<100 {
            if harness.writes.bytes.count >= expected.count { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(harness.writes.bytes == expected)
        #expect(!harness.session.enableHostGeometryResponses()) // no mid-stream ownership change

        let legacy = SurfaceHarness()
        defer { legacy.close() }
        try #require(legacy.session.restoreSnapshot(try legacy.snapshot(Data())))
        #expect(!legacy.session.enableHostGeometryResponses()) // no invented zero-pixel geometry
        #expect(!legacy.session.applyHostGeometry(columns: 80, rows: 24, cellWidthPixels: 9, cellHeightPixels: 18))
        #expect(legacy.session.enableHostIdentityResponses())

        let oversized = SurfaceHarness()
        defer { oversized.close() }
        try #require(oversized.session.restoreSnapshot(try oversized.snapshot(Data(), cellPixels: (65535, 18))))
        #expect(!oversized.session.enableHostGeometryResponses()) // imported metrics were not replaced by local pixels
        #expect(oversized.session.enableHostIdentityResponses())
    }

    @Test func nativeParserDoesNotAnswerEchoedDeviceRepliesAndReportsANSIModes() async throws {
        let harness = SurfaceHarness()
        defer { harness.close() }
        harness.feed(Data("\u{1B}[>1;10;0c\u{1B}[1c\u{1B}[>1c\u{1B}[=1c\u{1B}[>0;0c\u{1B}[4$p\u{1B}[4h\u{1B}[4$p\u{1B}[>0c".utf8))
        let expected = Data("\u{1B}[4;2$y\u{1B}[4;1$y\u{1B}[>1;10;0c".utf8)
        for _ in 0..<100 {
            if harness.writes.bytes.count >= expected.count { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(harness.writes.bytes == expected)
    }

    @Test func daemonIdentitySuppressesOnlyMatchingRepliesAndRequiresTheNativeClipboardPolicy() async throws {
        let version = try #require(InMemoryTerminalSession.runtimeVersion)
        let original = SurfaceHarness()
        original.feed(Data("\u{1B}[>q".utf8))
        let expected = Data("\u{1B}P>|ghostty \(version)\u{1B}\\".utf8)
        for _ in 0..<100 {
            if original.writes.bytes.count >= expected.count { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(original.writes.bytes == expected)
        original.close()

        let harness = SurfaceHarness()
        defer { harness.close() }
        #expect(!harness.session.enableHostIdentityResponses())
        let snapshot = try harness.snapshot(Data("\u{1B}P+q54".utf8))
        try #require(harness.session.restoreSnapshot(snapshot))
        try #require(harness.session.enableHostIdentityResponses())
        harness.feed(Data("4e\u{1B}\\\u{1B}[c\u{1B}[>c\u{1B}[=c\u{1B}[>q\u{1B}[6n\u{1B}[?5522$p".utf8))
        let clipboard = Data("\u{1B}[?5522;2$y".utf8)
        for _ in 0..<100 {
            if harness.writes.bytes.count >= clipboard.count { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(harness.writes.bytes == clipboard)
        #expect(!harness.session.enableHostIdentityResponses())
        harness.feed(Data("\u{1B}c\u{1B}[c\u{1B}[>q\u{1B}P+q544e\u{1B}\\\u{1B}[?5522$p".utf8))
        for _ in 0..<100 {
            if harness.writes.bytes.count >= 2 * clipboard.count { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(harness.writes.bytes == clipboard + clipboard)

        let denied = SurfaceHarness(controller: TerminalController { $0.withCustom("clipboard-write", "deny") })
        defer { denied.close() }
        try #require(denied.session.restoreSnapshot(try denied.snapshot(Data())))
        #expect(!denied.session.enableHostIdentityResponses())
        #expect(denied.session.enableHostStateResponses())
    }

    @Test func daemonOwnedStateQueriesAreSuppressedWithoutSuppressingNativeInputOrCapabilities() async throws {
        let harness = SurfaceHarness()
        defer { harness.close() }
        #expect(!harness.session.enableHostStateResponses())
        // A request split at the snapshot boundary must also remain daemon-owned.
        let snapshot = try harness.snapshot(Data("abc\u{1B}P$q".utf8))
        try #require(harness.session.restoreSnapshot(snapshot))
        try #require(harness.session.enableHostStateResponses())
        harness.feed(Data("m\u{1B}\\\u{1B}[6n\u{1B}[5n\u{1B}[?7$p\u{1B}[?9999$p\u{1B}[?u\u{1B}[?5522$p\u{1B}[>c".utf8))
        let expected = Data("\u{1B}[?5522;2$y\u{1B}[>1;10;0c".utf8)
        for _ in 0..<100 {
            if harness.writes.bytes.count >= expected.count { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(harness.writes.bytes == expected)
        #expect(!harness.session.enableHostStateResponses()) // no mid-stream switch
        try #require(harness.coordinator.surface?.paste(text: "USER_INPUT") == true)
        // RIS and subsequent queries must preserve the ownership contract.
        harness.feed(Data("\u{1B}c\u{1B}[6n\u{1B}[5n\u{1B}[?7$p\u{1B}[?u\u{1B}[>c".utf8))
        let final = expected + Data("USER_INPUT\u{1B}[>1;10;0c".utf8)
        for _ in 0..<100 {
            if harness.writes.bytes.count >= final.count { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(harness.writes.bytes == final)
    }

    @Test func restoredMetadataValidatesLocalURIsWithoutDisturbingParserContinuation() async throws {
        for (uri, title, expectedDirectory, expectedTitle) in [
            ("file://localhost/tmp/restored%20worktree", "Saved title", "/tmp/restored worktree", "Saved title"),
            ("file://craft-remote.invalid/tmp/remote", "Saved title", "", "Saved title"),
            ("https://localhost/tmp/remote", "Saved title", "", "Saved title"),
            ("", "Saved title", "", "Saved title"),
            ("file://localhost/tmp/fallback", "", "/tmp/fallback", "/tmp/fallback"),
        ] {
            let harness = SurfaceHarness()
            defer { harness.close() }
            let snapshot = try harness.snapshot(Data("\u{1B}]0;\(title)\u{07}\u{1B}]7;\(uri)\u{07}\u{1B}[31".utf8))
            try #require(harness.session.restoreSnapshot(snapshot))
            #expect(harness.metadata.titles.isEmpty && harness.metadata.directories.isEmpty)
            let memory = harness.session
            try #require(await Task.detached { memory.publishSnapshotMetadata() }.value)
            try #require(memory.flushSnapshotMetadataCallbacks())
            #expect(harness.metadata.titles.last == expectedTitle)
            #expect(harness.metadata.directories.last == expectedDirectory)
            #expect(harness.writes.bytes.isEmpty)
            harness.feed(Data("mLIVE_AFTER_METADATA".utf8))
            #expect(harness.text.contains("LIVE_AFTER_METADATA"))
            #expect(!memory.publishSnapshotMetadata())
        }
    }

    @Test(.timeLimit(.minutes(1))) func metadataCallbackCanCloseTheSurfaceWithoutHoldingAnActiveNativeOperation() async throws {
        let harness = SurfaceHarness()
        defer { harness.close() }
        let snapshot = try harness.snapshot(Data("\u{1B}]0;Close callback\u{07}".utf8))
        try #require(harness.session.restoreSnapshot(snapshot))
        let memory = harness.session
        harness.metadata.onTitle = { [weak harness] in harness?.close() }
        try #require(await Task.detached { memory.publishSnapshotMetadata() }.value)
        #expect(!memory.flushSnapshotMetadataCallbacks())
        #expect(harness.coordinator.surface == nil)
    }

    @Test func capturedGridIsRestoredIndependentlyOfTheCurrentViewGrid() async throws {
        let harness = SurfaceHarness()
        defer { harness.close() }
        try await Task.sleep(for: .milliseconds(50))
        let original = try #require(harness.coordinator.surface?.size())
        let snapshot = try harness.snapshot(Data(repeating: 120, count: Int(original.columns) + 5), extraColumn: true)
        try #require(harness.session.restoreSnapshot(snapshot))
        harness.feed(Data("\u{1B}[6n".utf8))
        let expected = Data("\u{1B}[2;5R".utf8)
        for _ in 0..<100 {
            if harness.writes.bytes.count >= expected.count { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(harness.writes.bytes == expected)
    }

    @Test func viewResizeWaitsForTheOrderedHostGridEventBeforeReflowingOutput() async throws {
        let harness = SurfaceHarness()
        defer { harness.close() }
        try await Task.sleep(for: .milliseconds(50))
        let surface = try #require(harness.coordinator.surface)
        let original = try #require(surface.size())
        let snapshot = try harness.snapshot(Data(repeating: 120, count: Int(original.columns) + 5))
        try #require(harness.session.restoreSnapshot(snapshot))
        surface.setSize(width: original.widthPixels + original.cellWidthPixels * 10, height: original.heightPixels)
        try await Task.sleep(for: .milliseconds(50))
        let changed = try #require(surface.size())
        #expect(changed.columns >= original.columns + 5)
        harness.feed(Data("\u{1B}[6n".utf8))
        let before = Data("\u{1B}[2;6R".utf8)
        for _ in 0..<100 {
            if harness.writes.bytes.count >= before.count { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(harness.writes.bytes == before)
        try #require(harness.session.applyHostGridSize(columns: changed.columns, rows: changed.rows))
        harness.feed(Data("\u{1B}[6n".utf8))
        let after = before + Data("\u{1B}[1;\(Int(original.columns) + 6)R".utf8)
        for _ in 0..<100 {
            if harness.writes.bytes.count >= after.count { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(harness.writes.bytes == after)
    }

    @Test func importsHistoryBothScreensSavedCursorAndFutureOutputWithoutHistoricalReplies() async throws {
        let harness = SurfaceHarness()
        defer { harness.close() }
        // Surface creation queues its initial pixel/grid resize to the IO thread.
        try await Task.sleep(for: .milliseconds(50))
        var history = ""
        for line in 0..<8000 { history += "history \(line) styled \u{1B}[32m日本語🦀\u{1B}[0m line\r\n" }
        history += "PRIMARY_MARKER\u{1B}[5;9H\u{1B}7\u{1B}[?2004h\u{1B}[?1h\u{1B}[6n\u{1B}[?1049hALT_MARKER\u{1B}[31"
        let input = Data(history.utf8)
        #expect(input.count > 256 * 1024)
        let snapshot = try harness.snapshot(input)
        try #require(harness.session.restoreSnapshot(snapshot))
        #expect(harness.text.contains("ALT_MARKER"))
        #expect(harness.writes.bytes.isEmpty)
        #expect(!harness.session.restoreSnapshot(snapshot))
        harness.feed(Data("mRED\u{1B}[0m\u{1B}[?1049l\u{1B}8AFTER_SAVED_CURSOR\u{1B}[6n".utf8))
        #expect(harness.text.contains("PRIMARY_MARKER") && harness.text.contains("AFTER_SAVED_CURSOR"))
        for _ in 0..<100 {
            if !harness.writes.bytes.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(String(decoding: harness.writes.bytes, as: UTF8.self) == "\u{1B}[5;27R")
        #expect(harness.coordinator.surface?.paste(text: "NATIVE_PASTE") == true)
        #expect(harness.coordinator.surface?.sendKey(.arrowUp) == true)
        let expectedInput = Data("\u{1B}[5;27R\u{1B}[200~NATIVE_PASTE\u{1B}[201~\u{1B}OA".utf8)
        for _ in 0..<100 {
            if harness.writes.bytes.count >= expectedInput.count { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(harness.writes.bytes == expectedInput)
        #expect(harness.coordinator.surface?.performBindingAction("scroll_to_top") == true)
        // The binding queues the viewport change on Ghostty's IO thread. Its
        // row-by-row text reader can otherwise observe the change mid-read.
        for _ in 0..<100 {
            if harness.text.hasPrefix("history 0 ") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(harness.text.contains("history 0"))
    }

    @Test func resumesSplitUTF8OSCAndDCSAndRejectsInvalidImportsWithoutChangingSurface() async throws {
        for (prefix, suffix, expected) in [
            (Data([0xf0, 0x9f]), Data([0xa6, 0x80]), "🦀"),
            (Data("\u{1B}]8;;https://example.com".utf8), Data("\u{1B}\\LINK\u{1B}]8;;\u{1B}\\".utf8), "LINK"),
            (Data("\u{1B}P$q".utf8), Data("m\u{1B}\\AFTER_DCS".utf8), "AFTER_DCS"),
            (Data("\u{1B}_Gf=24,s=1,v=1;".utf8), Data("/wAA\u{1B}\\AFTER_APC".utf8), "AFTER_APC"),
        ] {
            let harness = SurfaceHarness()
            defer { harness.close() }
            try await Task.sleep(for: .milliseconds(50))
            let snapshot = try harness.snapshot(prefix)
            let original = harness.text
            #expect(!harness.session.restoreSnapshot(snapshot.dropLast()))
            var corrupted = snapshot
            corrupted[30] ^= 1
            #expect(!harness.session.restoreSnapshot(corrupted))
            var trailing = snapshot
            trailing.append(0)
            #expect(!harness.session.restoreSnapshot(trailing))
            #expect(harness.text == original)
            try #require(harness.session.restoreSnapshot(snapshot))
            #expect(harness.writes.bytes.isEmpty)
            harness.feed(suffix)
            #expect(harness.text.contains(expected))
            #expect(!harness.session.restoreSnapshot(snapshot))
        }
    }
}
