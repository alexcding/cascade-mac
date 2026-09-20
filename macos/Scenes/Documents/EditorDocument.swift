import AppKit
import Foundation
import Observation

struct FileDocumentRecord: Codable, Identifiable, Equatable, Sendable {
    var id = UUID().uuidString
    let path: String
    var title: String { (path as NSString).lastPathComponent }
}

struct FileDocumentSnapshot: Codable, Sendable {
    let content: String
    let readOnly: Bool
    let revision: String
}

protocol FileDocumentService: Sendable {
    func load(path: String) async throws -> FileDocumentSnapshot
    func save(path: String, content: String, revision: String) async throws -> String
}

struct APIFileDocumentService: FileDocumentService {
    let api: APIClient
    func load(path: String) async throws -> FileDocumentSnapshot {
        try await api.get(APIClient.query(Routes.FILE, ["path": path]))
    }
    func save(path: String, content: String, revision: String) async throws -> String {
        struct Payload: Encodable, Sendable { let path: String; let content: String; let revision: String }
        struct Response: Decodable, Sendable { let revision: String }
        let result: Response = try await api.request(Routes.FILE, method: "PUT",
            body: Payload(path: path, content: content, revision: revision))
        return result.revision
    }
}

struct EditorBuffer: Codable, Sendable {
    let content: String
    let version: Int
    let dirty: Bool
}

@MainActor protocol EditorSurface: AnyObject {
    var view: NSView? { get }
    var changed: (Bool) -> Void { get set }
    var failed: (String) -> Void { get set }
    var saveRequested: () -> Void { get set }
    func load(_ value: FileDocumentSnapshot, path: String) async throws
    func snapshot(freeze: Bool) async throws -> EditorBuffer
    func acknowledge(version: Int) async throws -> Bool
    func unfreeze() async throws
    func setAppearance(_ value: AppAppearance)
    func setFont(_ value: CodeFont)
    func focus(line: Int, column: Int)
    func find()
    /// The code theme and the preview beside the text; a surface without them ignores it.
    func setStyle(_ value: EditorStyle)
    func dispose()
}

extension EditorSurface {
    func setStyle(_ value: EditorStyle) {}
}

// Swift owns the document identity and revision; the editor owns its buffer and
// undo stack. Saves acknowledge the submitted version, never a later edit.
@MainActor @Observable final class EditorDocumentViewModel: Identifiable {
    var presentation = DocumentPresentation() {
        didSet {
            guard oldValue != presentation else { return }
            if oldValue.appearance != presentation.appearance { setAppearance(presentation.appearance) }
            if oldValue.font != presentation.font { setFont(presentation.font) }
            if oldValue.editor != presentation.editor { setStyle(presentation.editor) }
            if oldValue.active != presentation.active {
                if presentation.active { show(appearance: presentation.appearance) } else { hide() }
            }
        }
    }
    let record: FileDocumentRecord
    nonisolated var id: String { record.id }
    var title: String { record.title }
    private(set) var dirty = false
    private(set) var readOnly = false
    private(set) var loading = false
    private(set) var saving = false
    private(set) var closing = false
    private(set) var loaded = false
    private(set) var error: String?
    private(set) var surface: (any EditorSurface)?
    var editorView: NSView? { surface?.view }
    @ObservationIgnored var changed: () -> Void = {}
    @ObservationIgnored private var service: (any FileDocumentService)?
    @ObservationIgnored private var makeSurface: (() -> any EditorSurface)?
    @ObservationIgnored private var revision: String?
    @ObservationIgnored private var loadingTask: Task<Void, Never>?
    @ObservationIgnored private var savingTask: Task<Bool, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var appearance = AppAppearance.system
    @ObservationIgnored private var font = CodeFont(size: 12)
    @ObservationIgnored private var style = EditorStyle()
    @ObservationIgnored private var visible = false
    @ObservationIgnored private var pendingLocation: DocumentLocation?

    init(record: FileDocumentRecord, service: (any FileDocumentService)? = nil,
         makeSurface: (() -> any EditorSurface)? = nil) {
        self.record = record; self.service = service; self.makeSurface = makeSurface
    }
    func connect(service: any FileDocumentService, makeSurface: @escaping () -> any EditorSurface) {
        self.service = service; self.makeSurface = makeSurface
        if presentation.active && !loaded { show(appearance: presentation.appearance) }
    }
    func retry() { if presentation.active { show(appearance: presentation.appearance) } }
    func show(appearance: AppAppearance) {
        visible = true
        self.appearance = appearance
        if loaded {
            surface?.setAppearance(appearance)
            if let location = pendingLocation { focus(line: location.line, column: location.column) }
            return
        }
        guard loadingTask == nil else { return }
        guard let service, let makeSurface else { error = "Connect to the backend to open this file."; return }
        loading = true; error = nil
        let generation = generation
        loadingTask = Task {
            defer { if self.generation == generation { loading = false; loadingTask = nil } }
            do {
                let value = try await service.load(path: record.path)
                try Task.checkCancellation()
                guard self.generation == generation else { return }
                try Self.validate(content: value.content, revision: value.revision)
                let editor = makeSurface()
                surface = editor
                wire(editor)
                try await editor.load(value, path: record.path)
                try Task.checkCancellation()
                guard self.generation == generation else { return }
                revision = value.revision; readOnly = value.readOnly; loaded = true
                editor.setAppearance(self.appearance)
                editor.setFont(self.font)
                editor.setStyle(self.style)
                if visible, let location = pendingLocation { focus(line: location.line, column: location.column) }
                if !visible { hide() }
            } catch {
                if !Task.isCancelled, self.generation == generation {
                    self.error = error.localizedDescription
                    surface?.dispose(); surface = nil
                }
            }
        }
    }
    func waitForLoad() async { await loadingTask?.value }
    private func wire(_ editor: any EditorSurface) {
        editor.changed = { [weak self] dirty in self?.dirty = dirty; self?.changed() }
        editor.failed = { [weak self] message in self?.error = message }
        editor.saveRequested = { [weak self] in Task { await self?.save() } }
    }
    func hide() {
        visible = false
        guard loaded, !saving, !closing, error == nil, let surface else { return }
        let generation = generation
        Task {
            guard let buffer = try? await surface.snapshot(freeze: true), self.generation == generation else { return }
            dirty = buffer.dirty
            if !visible, !saving, !closing, !dirty { dispose() }
            else if !closing { try? await surface.unfreeze() }
        }
    }
    @discardableResult func save() async -> Bool {
        if let savingTask { return await savingTask.value }
        guard loaded, !readOnly, let surface, let service, let revision else { return false }
        saving = true; error = nil
        let generation = generation
        let task = Task { [self] in
            do {
                let buffer = try await surface.snapshot(freeze: false)
                try Self.validate(content: buffer.content, revision: revision)
                if !buffer.dirty { dirty = false; return true }
                let nextRevision = try await service.save(path: record.path, content: buffer.content, revision: revision)
                try Self.validate(content: "", revision: nextRevision)
                guard self.generation == generation else { return false }
                // Persist the new revision even if the native surface fails during the ack.
                self.revision = nextRevision
                dirty = try await surface.acknowledge(version: buffer.version)
                changed()
                return true
            } catch {
                if self.generation == generation { self.error = error.localizedDescription }
                return false
            }
        }
        savingTask = task
        let success = await task.value
        savingTask = nil; saving = false
        return success
    }

    // Freeze before querying: a sheet/save may await, so later keystrokes cannot
    // arrive after the user approves closing. Dirty notifications alone race input.
    func beginClose() async throws -> Bool {
        guard !closing else { throw BackendError.operation("This file is already being closed.") }
        closing = true
        if let savingTask { _ = await savingTask.value }
        guard loaded, let surface else { return dirty }
        do {
            let buffer = try await surface.snapshot(freeze: true)
            dirty = buffer.dirty
            return dirty
        } catch {
            self.error = error.localizedDescription
            // A crashed editor cannot prove its last keystroke was clean. Require
            // an explicit discard; never silently close from a stale dirty flag.
            return true
        }
    }
    func cancelClose() async {
        if loaded { try? await surface?.unfreeze() }
        closing = false
    }
    func setAppearance(_ value: AppAppearance) { appearance = value; surface?.setAppearance(value) }
    func setFont(_ value: CodeFont) { font = value; surface?.setFont(value) }
    func find() { surface?.find() }
    func setStyle(_ value: EditorStyle) { style = value; surface?.setStyle(value) }
    func focus(line: Int = 1, column: Int = 1) {
        pendingLocation = .init(path: record.path, line: line, column: column)
        if loaded, visible { surface?.focus(line: line, column: column); pendingLocation = nil }
    }
    func dispose() {
        generation = UUID(); loadingTask?.cancel(); loadingTask = nil
        surface?.dispose(); surface = nil; loaded = false; loading = false
    }
    private static func validate(content: String, revision: String) throws {
        guard content.utf8.count <= 5 * 1024 * 1024, !content.contains("\0") else {
            throw BackendError.operation("Only UTF-8 text files up to 5 MB can be edited.")
        }
        guard revision.count == 64, revision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw BackendError.operation("The backend returned no valid file revision. Reopen the file after reconnecting.")
        }
    }
}
