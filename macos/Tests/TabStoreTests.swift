import Foundation
import Testing

private func temporaryTabsFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("cascade-tabs-\(UUID().uuidString)/tabs.json")
}

private func page(_ url: String, id: String? = nil, kind: String = "web", title: String = "", inTab: Bool = false) -> OpenPageRequest {
    var request = OpenPageRequest(id: id, url: url, kind: kind, title: title)
    request.inTab = inTab
    return request
}

@MainActor @Test func tabStoreOpensRenamesPinsReordersAndClosesLikeTheBackendDid() throws {
    let store = TabStore(fileURL: nil)
    // Opening a page always makes a new tab, active; the same page can be open twice.
    let first = try store.open(page("https://example.test/a", title: "A"))
    let second = try store.open(page("https://example.test/a"))
    #expect(second.tabs.count == 2 && second.tabs[0].id != second.tabs[1].id)
    #expect(second.active == second.tabs[1].id)
    // A page with no title yet is listed by its address, and a draft keeps the id it was given.
    #expect(second.tabs[1].title == "https://example.test/a")
    let draft = try store.open(page("https://example.test/d", id: "draft-1", title: "D", inTab: true))
    #expect(draft.tabs.last?.id == "draft-1" && draft.tabs.last?.standalone == true && draft.tabs.last?.paneView == "term")
    // Opening a tab that exists only makes it active.
    #expect(try store.open(page("https://example.test/a", id: first.tabs[0].id)).tabs.count == 3)
    #expect(store.saved.active == first.tabs[0].id)

    let renamed = store.rename(second.tabs[1].id, title: "Loaded")
    #expect(renamed.tabs[1].title == "Loaded" && renamed.tabs[0].title == "A")
    #expect(store.pin("draft-1", true).tabs.last?.pinned == true)
    #expect(store.pin("missing", true).tabs.count == 3)

    // Listed ids first, in order, a repeat keeping its first place; unknown ids ignored; the rest after.
    let reordered = store.reorder(["draft-1", "missing", second.tabs[1].id, "draft-1"])
    #expect(reordered.tabs.map(\.id) == ["draft-1", second.tabs[1].id, first.tabs[0].id])

    // Closing the active tab leaves none active; closing another keeps it.
    #expect(store.close(first.tabs[0].id).active == nil)
    #expect(store.close("draft-1").tabs.map(\.id) == [second.tabs[1].id])
    #expect(try store.open(page("https://example.test/z")).active != nil)
    #expect(store.close("missing").tabs.count == 2)
}

@MainActor @Test func tabStoreRefusesWhatTheBackendRefused() throws {
    let store = TabStore(fileURL: nil)
    #expect(throws: BackendError.self) { _ = try store.open(page("file:///etc/passwd")) }
    #expect(throws: BackendError.self) { _ = try store.open(page("https://user:secret@example.test/")) }
    #expect(throws: BackendError.self) { _ = try store.open(page("https://example.test/", kind: "mystery")) }
    #expect(store.tabs.isEmpty)
}

@MainActor @Test func tabStoreRoundTripsItsFileAndRemembersWhetherTheBackendListWasAdopted() throws {
    let file = temporaryTabsFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

    // A tab opened before the backend's list arrives writes the file, but is not the import.
    let early = TabStore(fileURL: file)
    #expect(early.needsImport)
    _ = try early.open(page("https://example.test/early", title: "Early"))
    #expect(early.needsImport && FileManager.default.fileExists(atPath: file.path))
    let relaunched = TabStore(fileURL: file)
    #expect(relaunched.needsImport && relaunched.tabs.map(\.title) == ["Early"])
    let earlyID = try #require(relaunched.tabs.first?.id)

    // The backend's list comes first; what was opened meanwhile follows it and stays the active
    // tab; the import is then done.
    let legacy = SavedTabs(tabs: [SavedTab(id: "old", kind: "github", title: "Old PR", url: "https://github.com/o/r/pull/1", pinned: true)], active: "old")
    relaunched.adopt(legacy)
    #expect(!relaunched.needsImport)
    #expect(relaunched.tabs.map(\.id) == ["old", earlyID] && relaunched.tabs[0].pinned && relaunched.saved.active == earlyID)
    relaunched.adopt(SavedTabs(tabs: [], active: nil)) // A second adoption changes nothing.
    #expect(relaunched.tabs.count == 2)

    let again = TabStore(fileURL: file)
    #expect(!again.needsImport && again.tabs.map(\.title) == ["Old PR", "Early"] && again.saved.active == earlyID)
    #expect(again.lastError == nil)
}

@MainActor @Test func tabStoreWithoutAFolderKeepsTabsForItsOwnLifeOnly() throws {
    let store = TabStore(fileURL: nil)
    _ = try store.open(page("https://example.test/x", title: "X"))
    store.adopt(SavedTabs(tabs: [], active: nil))
    #expect(store.tabs.count == 1 && !store.needsImport && store.lastError == nil)
    #expect(TabStore(fileURL: nil).tabs.isEmpty)
}

/// A tabs file this build wrote that no longer reads is set aside, and the backend's old list is
/// not adopted over it: that import happened already, and re-running it would bury every tab opened
/// or closed since. A Mac with no file at all still imports.
@MainActor @Test func anUnreadableTabsFileIsSetAsideAndNotImportedOver() throws {
    let url = temporaryTabsFile()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try Data("not json".utf8).write(to: url)
    let store = TabStore(fileURL: url)
    #expect(!store.needsImport && store.tabs.isEmpty && store.lastError == nil)
    #expect(store.takeRecoveryNotice() != nil && store.takeRecoveryNotice() == nil, "told once")
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("broken").path))
    #expect(TabStore(fileURL: temporaryTabsFile()).needsImport, "no file yet: the import is wanted")
}

/// A file that exists but could not be read at startup is not written over by the first change:
/// it is set aside then, so what was on disk is kept for a look.
@MainActor @Test func anUnreadTabsFileIsSetAsideBeforeTheFirstWrite() throws {
    let url = temporaryTabsFile()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try Data(#"{"tabs":[],"active":null,"imported":true}"#.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
    let store = TabStore(fileURL: url)
    #expect(!store.needsImport && store.tabs.isEmpty && store.takeRecoveryNotice() != nil)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    _ = try store.open(page("https://example.test/a", title: "A"))
    let aside = url.appendingPathExtension("broken")
    #expect(FileManager.default.fileExists(atPath: aside.path), "the unread file was kept")
    #expect(try String(contentsOf: aside, encoding: .utf8).contains("\"imported\":true"))
    // JSON escapes the slashes, so the host alone is looked for.
    #expect(try String(contentsOf: url, encoding: .utf8).contains("example.test"), "the new list was written")
}
