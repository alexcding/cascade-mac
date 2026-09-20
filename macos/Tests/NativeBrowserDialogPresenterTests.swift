import AppKit
import XCTest

// XCTest runs before the concurrent Swift Testing model suite. The native sheet
// changes NSApplication's global presentation state and must not overlap it.
final class NativeBrowserDialogPresenterTests: XCTestCase {
    @MainActor func testPromptAndOpenPanelCancellation() async throws {
        _ = NSApplication.shared
        let presenter = NativeBrowserDialogPresenter()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 480),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
            window.close()
        }
        var responses: [BrowserDialogViewModel.Response] = []
        let request = BrowserDialogViewModel.Request(origin: "example.test", kind: .prompt("Name", defaultText: "Original"))
        presenter.present(request, in: window) { responses.append($0) }()
        XCTAssertEqual(responses, [.cancel], "A hidden window cannot open a sheet")
        responses = []
        window.orderFront(nil)
        let cancelPrompt = presenter.present(request, in: window) { responses.append($0) }
        defer { cancelPrompt() }
        let sheet = try XCTUnwrap(window.attachedSheet)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let contents = descendants(try XCTUnwrap(sheet.contentView))
        let input = try XCTUnwrap(contents.compactMap { $0 as? NSTextField }.first {
            $0.accessibilityIdentifier() == "browser-dialog-input"
        })
        XCTAssertEqual(input.stringValue, "Original")
        input.stringValue = ""
        let okay = try XCTUnwrap(contents.compactMap { $0 as? NSButton }.first { $0.title == "OK" })
        okay.performClick(nil)
        for _ in 0..<100 {
            if !responses.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(responses, [.text("")], "Native OK must preserve an empty response")
        cancelPrompt()
        XCTAssertEqual(responses, [.text("")], "A completed sheet cannot be cancelled again")
        responses = []
        let cancelFiles = presenter.present(.init(origin: "upload.test", kind: .files(multiple: true, directories: true)),
                                            in: window) { responses.append($0) }
        defer { cancelFiles() }
        let panel = try XCTUnwrap(window.attachedSheet as? NSOpenPanel)
        XCTAssertTrue(panel.allowsMultipleSelection && panel.canChooseDirectories && panel.canChooseFiles)
        cancelFiles()
        for _ in 0..<100 {
            if !responses.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(responses, [.cancel])
        XCTAssertNil(window.attachedSheet)
    }
}
