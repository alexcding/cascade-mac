import AppKit
import CodeEditSourceEditor
import CodeEditTextView
import Foundation
import Testing

actor FileFixture: FileDocumentService {
    var writes: [String] = []
    var reads = 0
    var fails = false
    func fail(_ value: Bool) { fails = value }
    func load(path: String) async throws -> FileDocumentSnapshot {
        reads += 1
        return .init(content: "original", readOnly: false, revision: String(repeating: "a", count: 64))
    }
    func save(path: String, content: String, revision: String) async throws -> String {
        writes.append(content)
        try await Task.sleep(for: .milliseconds(70))
        if fails { throw BackendError.operation("File changed on disk") }
        return String(repeating: "b", count: 64)
    }
}

@MainActor final class BufferFixture: EditorSurface {
    var view: NSView? { nil }
    var changed: (Bool) -> Void = { _ in }
    var failed: (String) -> Void = { _ in }
    var saveRequested: () -> Void = {}
    var content = "original", version = 1, saved = 1
    var frozen = false, disposed = false
    func edit(_ text: String, notify: Bool = true) {
        guard !frozen else { return }
        content = text; version += 1
        if notify { changed(version != saved) }
    }
    func load(_ value: FileDocumentSnapshot, path: String) async throws {}
    func snapshot(freeze: Bool) async throws -> EditorBuffer {
        frozen = frozen || freeze
        return .init(content: content, version: version, dirty: version != saved)
    }
    func acknowledge(version: Int) async throws -> Bool { saved = version; return self.version != saved }
    func unfreeze() async throws { try Task.checkCancellation(); frozen = false }
    var appearances: [AppAppearance] = []
    var fonts: [CodeFont] = []
    func setAppearance(_ value: AppAppearance) { appearances.append(value) }
    func setFont(_ value: CodeFont) { fonts.append(value) }
    var location: (Int, Int)?
    func focus(line: Int, column: Int) { location = (line, column) }
    func find() {}
    func dispose() { disposed = true }
}

@MainActor @Test func nativeHiddenContextPreservesDirtyEditor() async throws {
    let viewer = ViewerStore()
    let context = viewer.select(id: "files", url: "session:files", title: "Files")
    let model = try #require(context.openFile("/tmp/unsaved.swift"))
    let surface = BufferFixture()
    model.connect(service: FileFixture(), makeSurface: { surface })
    model.show(appearance: .system); await model.waitForLoad()
    surface.edit("unsaved work")
    // Switching session hides the editor without closing it — nothing prompts to save on a
    // context switch, so an unsaved buffer that did not survive this would lose work silently.
    _ = viewer.select(id: "other", url: "session:other", title: "Other")
    #expect(viewer.active?.id == "other")
    #expect(context.documents.first === model && model.loaded && model.dirty)
    #expect(surface.content == "unsaved work" && !surface.disposed && !surface.frozen)
    await viewer.stop()
    model.dispose()
}

@MainActor @Test func nativeEditorSaveCoalescesAndAcknowledgesOnlySubmittedBuffer() async throws {
    let service = FileFixture(), surface = BufferFixture()
    let model = EditorDocumentViewModel(record: .init(path: "/tmp/test.swift"), service: service, makeSurface: { surface })
    model.show(appearance: .system); await model.waitForLoad()
    #expect(model.loaded && model.error == nil)
    surface.edit("first")
    let first = Task { await model.save() }
    // Wait until the first write has begun, by a deadline rather than a fixed count: a busy
    // parallel test run can take longer than a few hundred milliseconds to get there.
    let deadline = Date().addingTimeInterval(3)
    while await service.writes.count != 1 && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
    surface.edit("new edit during save")
    let second = Task { await model.save() }
    #expect(await first.value)
    #expect(await second.value)
    #expect(await service.writes == ["first"])
    #expect(model.dirty && surface.content == "new edit during save")
    await service.fail(true)
    #expect(await model.save() == false)
    #expect(model.dirty && model.error == "File changed on disk")
    await service.fail(false)
    #expect(await model.save())
    #expect(!model.dirty)
}

@MainActor @Test func workflowPagePromotionPreservesUnsavedEditorBuffer() async throws {
    let viewer = ViewerStore()
    let context = viewer.select(id: "tab:workflow", url: "session:fixture", title: "Workflow")
    let model = try #require(context.openFile("/tmp/workflow-unsaved.swift"))
    let surface = BufferFixture()
    model.connect(service: FileFixture(), makeSurface: { surface })
    model.show(appearance: .system); await model.waitForLoad()
    surface.edit("Unsaved before preparation")
    try viewer.promoteContext(from: "tab:workflow", to: "task:workflow")
    #expect(viewer.active === context && context.activeDocument === model)
    #expect(model.loaded && model.dirty && surface.content == "Unsaved before preparation")
    #expect(!surface.disposed && !surface.frozen)
    let existing = viewer.select(id: "task:existing", url: "session:existing", title: "Existing")
    let existingModel = try #require(existing.openFile("/tmp/existing-unsaved.swift"))
    let existingSurface = BufferFixture()
    existingModel.connect(service: FileFixture(), makeSurface: { existingSurface })
    existingModel.show(appearance: .system); await existingModel.waitForLoad()
    existingSurface.edit("Existing session edits")
    _ = viewer.select(id: "task:workflow", url: "session:fixture", title: "Workflow")
    try viewer.promoteContext(from: "task:workflow", to: "task:existing")
    #expect(viewer.active === existing && existing.activeDocument === model)
    #expect(existing.documents.count == 2 && existingModel.dirty && model.dirty)
    #expect(existingSurface.content == "Existing session edits" && surface.content == "Unsaved before preparation")
    #expect(!existingSurface.disposed && !surface.disposed)
    await viewer.stop(); model.dispose(); existingModel.dispose()
}

@MainActor @Test func nativeEditorCloseFreezesQueriesLatestBufferAndCancelKeepsEveryDocument() async throws {
    let service = FileFixture(), surface = BufferFixture()
    let model = EditorDocumentViewModel(record: .init(path: "/tmp/close.swift"), service: service, makeSurface: { surface })
    model.show(appearance: .system); await model.waitForLoad()
    surface.edit("last keystroke", notify: false)
    #expect(!model.dirty) // The async WebKit notification has not arrived.
    let presenter = EditorClosePresenterFixture(), coordinator = EditorCloseCoordinator(presenter: presenter)
    var prompts = 0
    presenter.chooseAction = { _ in
        prompts += 1
        #expect(model.dirty && surface.frozen)
        surface.edit("must not be accepted")
        return .cancel
    }
    let approved = await coordinator.close([model], commit: { model.dispose() })
    #expect(!approved && prompts == 1 && !surface.frozen && !model.closing)
    #expect(surface.content == "last keystroke" && !surface.disposed)
    await service.fail(true)
    prompts = 0
    presenter.chooseAction = { _ in
        prompts += 1
        return prompts == 1 ? .save : .cancel
    }
    #expect(await coordinator.close([model], commit: { model.dispose() }) == false)
    #expect(prompts == 2 && model.dirty && !surface.disposed)
    presenter.chooseAction = { _ in .discard }
    #expect(await coordinator.close([model], commit: { model.dispose() }))
    #expect(surface.disposed)
}

// A hidden editor stays loaded, clean or dirty, so its tab or session comes back instantly;
// hiding still asks the buffer whether it holds unsaved edits.
@MainActor @Test func nativeEditorHiddenBuffersStayLoadedAndReportDirty() async throws {
    let service = FileFixture(), surface = BufferFixture()
    let model = EditorDocumentViewModel(record: .init(path: "/tmp/cache.swift"), service: service, makeSurface: { surface })
    model.show(appearance: .system); await model.waitForLoad()
    surface.edit("unsaved", notify: false)
    model.hide()
    for _ in 0..<10 { await Task.yield() }
    #expect(model.loaded && model.dirty && !surface.disposed && !surface.frozen)
    model.show(appearance: .system)
    #expect(await model.save())
    model.hide()
    for _ in 0..<10 { await Task.yield() }
    #expect(model.loaded && !model.dirty && !surface.disposed && !surface.frozen)
    model.dispose()
}

@MainActor @Test func fileAndWebTabsShareOrderHistoryAndRestoreActiveFiles() throws {
    let legacy = SavedTab(kind: "web", title: "Root", url: "https://example.com", links: [
        .init(kind: "file", path: "/tmp/one.swift"), .init(url: "https://example.com/two", title: "Two"),
        .init(kind: "file", path: "/tmp/three.swift", active: true)])
    #expect(SavedTabContent(kind: "file", url: "file:///tmp/file%20name.swift").filePath == "/tmp/file name.swift")
    #expect(SavedTabContent(kind: "file", url: "https://example.com/secret").filePath == nil)
    let snapshot = ContextSnapshot.importing(legacy)
    let context = WorkspaceContext(id: "files", sourceURL: legacy.url, title: "", snapshot: snapshot)
    #expect(context.tabs.map(\.title) == ["Root", "one.swift", "Two", "three.swift"])
    #expect(context.activeDocument?.record.path == "/tmp/three.swift")
    let first = try #require(context.documents.first)
    context.select(.file(first))
    let fourth = try #require(context.open("https://example.com/four", title: "Four"))
    #expect(context.tabs.map(\.title) == ["Root", "one.swift", "Four", "Two", "three.swift"])
    context.close(fourth)
    context.remove(first)
    #expect(context.visits.suffix(2).map(\.title) == ["Four", "/tmp/one.swift"])
    let data = try JSONEncoder().encode(context.snapshot)
    let restored = WorkspaceContext(id: "files", sourceURL: legacy.url, title: "", snapshot: try JSONDecoder().decode(ContextSnapshot.self, from: data))
    #expect(restored.tabOrder == context.tabOrder)
    #expect(restored.documents.count == 1) // Legacy metadata must not resurrect the closed file.
    #expect(restored.visits.map(\.title) == context.visits.map(\.title))
}

@MainActor @Test func codeEditEditorSurfaceLoadsEditsAndTracksSavedVersions() async throws {
    _ = NSApplication.shared
    let surface = CodeEditEditorSurface()
    try await surface.load(.init(content: "let title = \"Unicode 🦊\"\n", readOnly: false,
                                 revision: String(repeating: "a", count: 64)), path: "/tmp/Fixture.swift")
    let initial = try await surface.snapshot(freeze: false)
    #expect(initial.content == "let title = \"Unicode 🦊\"\n" && !initial.dirty)
    let textView = try #require(surface.view?.descendantSourceTextView)
    textView.replaceCharacters(in: NSRange(location: textView.string.utf16.count, length: 0), with: "// edited\n")
    let edited = try await surface.snapshot(freeze: true)
    #expect(edited.dirty && edited.content.hasSuffix("// edited\n"))
    #expect(!textView.isEditable) // Frozen while the save is in flight.
    #expect(try await surface.acknowledge(version: edited.version) == false)
    try await surface.unfreeze()
    #expect(textView.isEditable)
    surface.dispose()
    #expect(surface.view == nil)
}

@Test func codeThemesFallBackToTheDefaultForUnknownOrMismatchedNames() {
    #expect(CodeTheme.named("Dracula", dark: true).name == "Dracula")
    // A dark theme is not offered for the light appearance, and an unknown name degrades quietly.
    #expect(CodeTheme.named("Dracula", dark: false) == CodeTheme.standard(dark: false))
    #expect(CodeTheme.named("Removed Theme", dark: true) == CodeTheme.standard(dark: true))
    #expect(EditorStyle(darkTheme: "One Dark", lightTheme: "").theme(dark: true).name == "One Dark")
    #expect(Set(CodeTheme.names(dark: true)).isDisjoint(with: CodeTheme.names(dark: false)))
}

@MainActor @Test func codeEditEditorSurfaceAppliesTheStyleItIsGivenBeforeAndAfterLoading() async throws {
    _ = NSApplication.shared
    let surface = CodeEditEditorSurface()
    surface.setStyle(EditorStyle(darkTheme: "Dracula", lightTheme: "Solarized Light", showMinimap: false))
    try await surface.load(.init(content: "let a = 1\n", readOnly: false, revision: String(repeating: "a", count: 64)),
                           path: "/tmp/Fixture.swift")
    let controller = try #require(surface.view?.descendantSourceTextView?.delegate as? TextViewController)
    #expect(!controller.configuration.peripherals.showMinimap)
    let background = controller.configuration.appearance.theme.background
    #expect([CodeTheme.color(0x282A36), CodeTheme.color(0xFDF6E3)].contains(background))
    surface.setStyle(EditorStyle(showMinimap: true))
    #expect(controller.configuration.peripherals.showMinimap)
    surface.dispose()
}

private extension NSView {
    var descendantSourceTextView: TextView? {
        if let text = self as? TextView { return text }
        return subviews.lazy.compactMap(\.descendantSourceTextView).first
    }
}


@MainActor @Test func editorLocationSurvivesLoadingAndReopeningExistingDocument() async {
    let surface = BufferFixture()
    let model = EditorDocumentViewModel(record: .init(path: "/tmp/location.swift"), service: FileFixture(), makeSurface: { surface })
    model.focus(line: 20, column: 7)
    model.show(appearance: .system)
    await model.waitForLoad()
    #expect(surface.location?.0 == 20 && surface.location?.1 == 7)
    model.focus(line: 30, column: 2)
    #expect(surface.location?.0 == 30 && surface.location?.1 == 2)
    model.dispose()
}

@MainActor @Test func browserAndFilesModesKeepSeparateTabsAndSelections() throws {
    let context = WorkspaceContext(id: "task:modes", sourceURL: "session:modes", title: "")
    let home = try #require(context.open("https://example.com/home", title: "Home"))
    let docs = try #require(context.open("https://example.com/docs", title: "Docs"))
    #expect(context.pane == .term && context.lastMode == .browser)
    let first = try #require(context.openFile("/tmp/first.swift"))
    #expect(context.pane == .files && context.activeDocument === first && context.activePage == nil)
    #expect(context.fileTabs.map(\.id) == [first.id] && context.pageTabs.map(\.id) == [home.id, docs.id])
    let second = try #require(context.openFile("/tmp/second.swift"))
    context.cycle(1)
    #expect(context.activeDocument === first, "cycling stays within the Files tabs")
    context.setPane(.term)
    #expect(context.activePage === docs && context.activeDocument == nil, "Browser restores its last page")
    context.setPane(.off)
    #expect(context.lastMode == .browser)
    context.setPane(.files)
    #expect(context.activeDocument === first, "Files restores its last file, not the last opened")
    context.remove(first)
    #expect(context.activeDocument === second, "closing a file picks a file neighbour, never a page")
    context.remove(second)
    #expect(context.activeID == nil && context.pane == .files, "an emptied mode stays selected and blank")
    context.setPane(.term)
    #expect(context.activePage === docs)
    let snapshot = context.snapshot
    let restored = WorkspaceContext(id: context.id, sourceURL: "session:modes", title: "", snapshot: snapshot)
    #expect(restored.pane == .term && restored.activePage?.id == docs.id)
}

private actor RevisableFileFixture: FileDocumentService {
    var content = "original"
    var revision = String(repeating: "a", count: 64)
    var reads = 0
    func change() { revision = String(repeating: "b", count: 64); content = "changed on disk" }
    func load(path: String) async throws -> FileDocumentSnapshot {
        reads += 1
        return .init(content: content, readOnly: false, revision: revision)
    }
    func save(path: String, content: String, revision: String) async throws -> String { revision }
}

@MainActor @Test func editorRevalidateRebuildsTheSurfaceWhenTheFileChangedAndTheBufferIsClean() async throws {
    let service = RevisableFileFixture()
    var surfaces: [BufferFixture] = []
    let model = EditorDocumentViewModel(record: .init(path: "/tmp/revalidate.swift"), service: service,
                                        makeSurface: { let surface = BufferFixture(); surfaces.append(surface); return surface })
    model.show(appearance: .system); await model.waitForLoad()
    let first = try #require(surfaces.first)
    #expect(surfaces.count == 1)
    model.hide()
    await service.change()
    model.show(appearance: .system)
    let deadline = Date().addingTimeInterval(3)
    while !first.disposed && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    #expect(first.disposed)
    #expect(surfaces.count == 2)
    #expect(model.loaded && !model.dirty)
    let second = try #require(surfaces.last)
    #expect(!second.disposed)
    model.focus(line: 7, column: 2)
    #expect(second.location?.0 == 7 && second.location?.1 == 2)
    #expect(first.location == nil)
    model.dispose()
}

@MainActor @Test func editorRevalidateKeepsADirtySurfaceWhenTheFileChanged() async throws {
    let service = RevisableFileFixture()
    let surface = BufferFixture()
    let model = EditorDocumentViewModel(record: .init(path: "/tmp/dirty-revalidate.swift"), service: service, makeSurface: { surface })
    model.show(appearance: .system); await model.waitForLoad()
    surface.edit("dirty edit")
    model.hide()
    await service.change()
    model.show(appearance: .system)
    let deadline = Date().addingTimeInterval(3)
    while await service.reads < 2 && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    for _ in 0..<20 { await Task.yield() }
    try await Task.sleep(for: .milliseconds(50))
    #expect(!surface.disposed && !surface.frozen)
    #expect(surface.content == "dirty edit")
    model.dispose()
}

@MainActor @Test func editorRevalidateKeepsTheSurfaceWhenTheFileIsUnchanged() async throws {
    let service = RevisableFileFixture()
    var surfaces: [BufferFixture] = []
    let model = EditorDocumentViewModel(record: .init(path: "/tmp/unchanged.swift"), service: service,
                                        makeSurface: { let surface = BufferFixture(); surfaces.append(surface); return surface })
    model.show(appearance: .system); await model.waitForLoad()
    model.hide()
    model.show(appearance: .system)
    let deadline = Date().addingTimeInterval(3)
    while await service.reads < 2 && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    for _ in 0..<20 { await Task.yield() }
    #expect(surfaces.count == 1)
    #expect(!surfaces[0].disposed)
    model.dispose()
}
