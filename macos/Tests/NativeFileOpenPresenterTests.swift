import AppKit
import XCTest

// Keep real AppKit presentation ahead of the concurrent Swift Testing models.
final class NativeFileOpenPresenterTests: XCTestCase {
    @MainActor func testFileOnlyPanelCancellationAndUnavailableWindow() async throws {
        _ = NSApplication.shared
        let presenter = NativeFileOpenPresenter()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 480),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var responses: [URL?] = []
        presenter.present(in: nil, directory: nil) { responses.append($0) }()
        presenter.present(in: window, directory: nil) { responses.append($0) }()
        XCTAssertEqual(responses.count, 2)
        XCTAssertTrue(responses.allSatisfy { $0 == nil })
        window.orderFront(nil)
        let cancel = presenter.present(in: window, directory: nil) { responses.append($0) }
        defer { cancel() }
        let panel = try XCTUnwrap(window.attachedSheet as? NSOpenPanel)
        XCTAssertTrue(panel.canChooseFiles)
        XCTAssertFalse(panel.canChooseDirectories || panel.allowsMultipleSelection)
        presenter.present(in: window, directory: nil) { responses.append($0) }()
        XCTAssertEqual(responses.count, 3, "An attached sheet prevents a second picker")
        cancel()
        for _ in 0..<100 {
            if responses.count == 4 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(responses.count, 4)
        XCTAssertNil(window.attachedSheet)
        XCTAssertTrue(responses.allSatisfy { $0 == nil })
        cancel()
        XCTAssertEqual(responses.count, 4)
    }
}
