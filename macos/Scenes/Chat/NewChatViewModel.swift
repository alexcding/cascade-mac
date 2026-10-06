import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// New Chat: which agent and which of its models. New Task's chat belongs to no project: it works in
/// a private scratch folder the backend makes for it, or in a folder picked with `changeFolder` (the
/// logic is here; New Task shows no folder control yet). A session
/// pane's chat works in the session's worktree, and may start with what the session's agent knows.
/// The chat starts asking before every tool call (`approval-required`), and is titled "New Chat"
/// until the backend titles it from the first message.
///
/// Files picked, pasted or dropped into the composer sit in `prompt` as chips (`ChatComposing`, as
/// the terminal chat's overlay holds them) and go with the first message: an image is saved for the
/// chat (`attachments.save`) and carried in `message.attachments`; any other file, and a folder, is
/// named in the text as an `@path` mention for the agent to read itself.
@MainActor @Observable final class NewChatViewModel {
    enum Action: Equatable {
        /// The chat exists; its shell as far as the app knows it until the backend's arrives.
        case created(ChatThreadShell)
    }

    struct Agent: Identifiable, Equatable {
        let cli: String
        let provider: String
        let name: String
        /// Installed and enabled: a chat can start on it.
        let usable: Bool
        /// Why not, when it is not.
        let note: String?
        var id: String { cli }
    }

    /// The session a chat started in its pane may start knowing from: its agent's CLI (nil or
    /// unknown for a plain shell) and the conversation the app knows the agent is in.
    struct SessionKnowledge: Equatable {
        let cli: String?
        let conversationID: String?
    }

    /// Nil for a standalone chat.
    let projectID: String?
    /// The project's name, or nil for a standalone chat.
    let projectName: String?
    /// The folder the chat works in; empty for New Task's chat, which works in a scratch folder of
    /// its own.
    private(set) var folder: String
    /// The session worktree a chat started in a session's pane is tagged with; nil elsewhere.
    let worktreePath: String?
    private(set) var agents: [Agent] = []
    var agent: String? { didSet { if oldValue != agent { Task { await loadModels() } } } }
    private(set) var models: [ChatModelOption] = []
    var model: String?
    private(set) var loading = false
    private(set) var loadingModels = false
    private(set) var busy = false
    private(set) var error: String?
    private(set) var retired = false
    /// The session whose agent's knowledge a pane's form offers to start with; nil elsewhere.
    let knowledgeSession: SessionKnowledge?
    /// Start with what the session's agent knows. Off unless the person turns it on.
    var includeKnowledge = false
    /// The first message: sent as the chat's first turn once it exists. Each attached file sits in
    /// it as one `ChatCompletion.fileMark`, which the field draws as a chip.
    var prompt = "" {
        didSet {
            let marks = ChatCompletion.markCount(in: prompt)
            if attachments.count > marks { attachments = Array(attachments.prefix(marks)) }
        }
    }
    /// Files the first message carries, in the order their marks appear in `prompt`.
    private(set) var attachments: [ChatAttachment] = []
    /// Where the field's caret is, in UTF-16 units of `prompt`; nil while text is selected.
    private(set) var caret: Int?
    /// Files still being read or staged (a pasted screenshot, a dropped file); Start waits for them.
    private(set) var staging = 0
    /// Bumped to hand the keyboard to the message field.
    private(set) var focusRequest = 0
    /// The last request the field acted on (`ChatComposing.focusTaken`); not drawn.
    @ObservationIgnored var focusTaken = 0
    /// The chat made for a Start whose first message then failed: Start again sends it there
    /// rather than making another chat.
    private(set) var startedShell: ChatThreadShell?
    /// The session agent's conversation the backend found, once asked; nil when it has none yet.
    private(set) var knowledgeConversation: String?
    private(set) var knowledgeChecked = false
    @ObservationIgnored var onAction: (Action) -> Void = { _ in }
    @ObservationIgnored private let service: any ChatServing
    @ObservationIgnored private let chooseFolder: (String) async -> String?
    @ObservationIgnored private var statuses: [String: ChatProviderStatus] = [:]
    @ObservationIgnored private var modelsRequest = UUID()
    /// Images already saved for `startedShell`, by attachment: a Start sent again after a failure
    /// does not save them twice.
    @ObservationIgnored private var saved: [ChatAttachment.ID: JSONValue] = [:]
    /// The form made anew to take this one's place: files still staging here are placed there.
    @ObservationIgnored private weak var successor: NewChatViewModel?

    /// `agent` is the CLI to offer first, when it is usable: a session's own, in its pane.
    init(projectID: String?, projectName: String?, folder: String, service: any ChatServing,
         chooseFolder: @escaping (String) async -> String? = { _ in nil },
         worktreePath: String? = nil, agent: String? = nil, knowledgeSession: SessionKnowledge? = nil) {
        self.projectID = projectID
        self.knowledgeSession = knowledgeSession
        self.projectName = projectName
        self.folder = folder
        self.worktreePath = worktreePath
        self.agent = agent
        self.service = service
        self.chooseFolder = chooseFolder
    }

    var standalone: Bool { projectID == nil }

    /// Whether the form offers to start with the session agent's knowledge as a switch: in a pane only.
    var offersKnowledge: Bool { knowledgeSession != nil }

    /// The agent and model, as the composer's agent menu names them.
    var agentTitle: String {
        guard let driver = AgentDrivers.of(agent) else { return String(localized: "Choose an agent") }
        guard let name = models.first(where: { $0.slug == model })?.title else { return driver.shortName }
        return name.localizedCaseInsensitiveContains(driver.shortName) ? name : "\(driver.shortName) \(name)"
    }
    /// The agent's mark on that menu.
    var agentMark: SessionAgent { agent.flatMap(SessionAgent.init(rawValue:)) ?? .shell }
    /// New Task's field, before anything is typed.
    var askPlaceholder: String {
        guard let name = AgentDrivers.of(agent)?.shortName else { return String(localized: "Ask anything") }
        if folder.isEmpty { return String(localized: "Ask \(name) anything") }
        return standalone ? String(localized: "Ask \(name) about this folder") : String(localized: "Ask \(name) about this project")
    }
    /// The session's agent, as the form names it.
    var knowledgeAgentName: String { AgentDrivers.of(knowledgeSession?.cli)?.shortName ?? String(localized: "the session’s agent") }
    var canIncludeKnowledge: Bool { !retired && !busy && knowledgeConversation != nil }
    /// Why the knowledge cannot be included, when it cannot.
    var knowledgeUnavailableReason: String? {
        guard let session = knowledgeSession else { return nil }
        if AgentDrivers.of(session.cli) == nil { return String(localized: "This session runs no agent.") }
        guard knowledgeChecked else { return nil }
        return knowledgeConversation == nil ? String(localized: "The session’s agent has no conversation yet.") : nil
    }

    /// Asks the backend whether the session's agent has a conversation to start from.
    /// Only the conversation the app knows the agent is in counts: without one there is nothing
    /// to ask for, and no other conversation of the worktree stands in for it.
    func checkKnowledge() async {
        guard !retired, let session = knowledgeSession, let driver = AgentDrivers.of(session.cli) else { return }
        guard let conversation = session.conversationID, !conversation.isEmpty else {
            knowledgeConversation = nil; knowledgeChecked = true; includeKnowledge = false
            return
        }
        let found = try? await service.sessionKnowledge(provider: driver.chatProvider, worktree: folder,
                                                        conversationID: conversation)
        // A session picked again while this was asked has its own answer coming.
        guard !retired, knowledgeSession == session else { return }
        knowledgeConversation = found
        knowledgeChecked = true
        if knowledgeConversation == nil { includeKnowledge = false }
    }

    /// What the chat starts knowing, when the person asked for it and there is something to know.
    private var knowledge: ChatKnowledgeSource? {
        guard includeKnowledge, let conversation = knowledgeConversation,
              let driver = AgentDrivers.of(knowledgeSession?.cli) else { return nil }
        return ChatKnowledgeSource(provider: driver.chatProvider, conversationID: conversation)
    }
    var canCreate: Bool {
        !retired && !busy && (standalone || !folder.isEmpty) && agents.contains { $0.cli == agent && $0.usable } && !(model ?? "").isEmpty
    }

    private var typedPrompt: String { ChatCompletion.text(of: prompt) }
    /// Start: only once something is typed or attached, and every file is ready; the chat starts with it.
    var canStart: Bool { canCreate && staging == 0 && (!typedPrompt.isEmpty || !attachments.isEmpty) }

    /// A pane's Start: makes the chat and sends the typed text as its first message.
    func start() async {
        guard canStart else { return }
        await create()
    }

    /// The providers, then the chosen agent's models.
    func load() async {
        guard !retired else { return }
        loading = true
        defer { loading = false }
        do {
            let value = try await service.providerStatuses()
            guard !retired else { return }
            let list = (value.array ?? []).compactMap { try? $0.decode(ChatProviderStatus.self) }
            statuses = Dictionary(list.compactMap { status in status.kind.map { ($0, status) } }, uniquingKeysWith: { first, _ in first })
            error = nil
        } catch {
            guard !retired else { return }
            statuses = [:]
            self.error = error.localizedDescription
        }
        agents = AgentDrivers.all.map { driver in
            let status = statuses[driver.chatProvider]
            let usable = status?.usable ?? false
            let note: String? = usable ? nil
                : status == nil ? String(localized: "Not available")
                : status?.message ?? (status?.enabled == false ? String(localized: "Turned off") : String(localized: "Not installed"))
            return Agent(cli: driver.cli, provider: driver.chatProvider, name: driver.shortName, usable: usable, note: note)
        }
        let chosen = agents.first { $0.cli == agent && $0.usable } ?? agents.first(where: \.usable)
        // A change of agent reads its models by itself, but the form waits for them here.
        if chosen?.cli != agent { agent = chosen?.cli }
        await loadModels()
        await checkKnowledge()
    }

    /// The chosen agent's models: the ones its status lists, else what `provider.listModels` says.
    func loadModels() async {
        guard !retired, let agent = agents.first(where: { $0.cli == self.agent }) else { models = []; model = nil; return }
        let request = UUID()
        modelsRequest = request
        loadingModels = true
        defer { if modelsRequest == request { loadingModels = false } }
        var list = statuses[agent.provider]?.models ?? []
        if list.isEmpty {
            do { list = try await service.listModels(provider: agent.provider, cwd: folder.isEmpty ? nil : folder) }
            catch {
                guard !retired, modelsRequest == request else { return }
                self.error = error.localizedDescription
            }
        }
        guard !retired, modelsRequest == request else { return }
        models = list
        if !list.contains(where: { $0.slug == model }) { model = (list.first { $0.isDefault == true } ?? list.first)?.slug }
    }

    /// A standalone chat's folder, picked; the models are read again for it, since a CLI may offer
    /// a folder its own. Cancelled, the chat stays where it was.
    func changeFolder() async {
        guard !retired, standalone, !busy, startedShell == nil, let picked = await chooseFolder(folder), !retired,
              !picked.isEmpty, picked != folder else { return }
        folder = picked
        await loadModels()
    }

    /// A form made anew (on reconnect) keeps the folder the one before had picked.
    func carryFolder(from previous: NewChatViewModel) {
        guard !retired, standalone, previous.standalone, startedShell == nil else { return }
        folder = previous.folder
    }

    /// Back to a scratch folder of the chat's own.
    func clearFolder() async {
        guard !retired, standalone, !busy, startedShell == nil, !folder.isEmpty else { return }
        folder = ""
        await loadModels()
    }

    /// A project chat works in its project's folder: one with none set cannot start a chat.
    var missingFolder: Bool { !standalone && folder.isEmpty }

    /// Makes the chat and, when something is typed, sends it as the first message. The form gives way
    /// to the chat only once both are done; a message that could not be sent stays in the field, and
    /// Start sends it again to the chat already made.
    func create() async {
        guard canCreate, staging == 0, let agent = agents.first(where: { $0.cli == self.agent }), let model else { return }
        busy = true; error = nil
        defer { busy = false }
        let project = projectID ?? ChatProject.standalone
        let title = ChatProject.untitled
        let draft = prompt
        let files = attachments
        do {
            // Read before the chat is made: an image too large, or one gone, makes no chat.
            let parts = try await ChatFirstMessage.read(files, saved: Set(saved.keys))
            guard !retired else { return }
            let shell: ChatThreadShell
            if let startedShell {
                shell = startedShell
            } else {
                // No folder: the backend makes the chat a scratch folder of its own, and says which.
                let created = try await service.createThread(projectID: project, cwd: folder.isEmpty ? nil : folder,
                                                             provider: agent.provider, model: model,
                                                             worktreePath: worktreePath, knowledge: knowledge, title: title)
                let now = ChatTimestamp.string()
                shell = ChatThreadShell(id: created.id, projectId: project, title: title,
                                        modelSelection: .init(provider: agent.provider, model: model),
                                        runtimeMode: "approval-required",
                                        workingDirectory: created.workingDirectory ?? folder, worktreePath: worktreePath,
                                        createdAt: now, updatedAt: now)
                // Kept by the form made anew meanwhile too, so its Start makes no second chat.
                for form in heirs where form.startedShell == nil { form.startedShell = shell }
            }
            guard !retired else { return }
            var images: [JSONValue] = []
            for part in parts {
                let file: ChatAttachment, name: String, mimeType: String, data: Data
                switch part {
                case .mention: continue
                case .saved(let done):
                    guard let attachment = saved[done.id] else { continue }
                    images.append(attachment); continue
                case .image(let picked, let pickedName, let pickedType, let pickedData):
                    (file, name, mimeType, data) = (picked, pickedName, pickedType, pickedData)
                }
                // Off the main actor: the image is encoded as base64 for the call.
                let service = service, threadID = shell.id
                let attachment = try await Task.detached(priority: .userInitiated) {
                    try await service.saveAttachment(threadID: threadID, name: name, mimeType: mimeType, data: data)
                }.value
                // Kept before anything else, by the form made anew meanwhile too, so its Start
                // sends the saved copy rather than uploading the image again.
                for form in heirs where form.startedShell?.id == shell.id { form.saved[file.id] = attachment }
                guard !retired else { return }
                images.append(attachment)
            }
            let text = ChatFirstMessage.text(draft, parts: parts)
            if !text.isEmpty || !images.isEmpty {
                let selection = shell.modelSelection
                try await service.startTurn(threadID: shell.id, text: text, provider: selection?.provider ?? agent.provider,
                                            model: selection?.model ?? model, attachments: images)
                guard !retired else { return }
            }
            onAction(.created(shell))
        } catch {
            guard !retired else { return }
            self.error = error.localizedDescription
        }
    }

    /// This form and each made anew in turn to take its place.
    private var heirs: [NewChatViewModel] {
        var forms = [self]
        while let next = forms.last?.successor, !forms.contains(where: { $0 === next }) { forms.append(next) }
        return forms
    }

    func retire() {
        retired = true
        onAction = { _ in }
    }

    /// A form made anew (on reconnect) keeps what the one before had typed and attached, the chat
    /// a failed Start already made and the images it saved for it, so Start again sends there
    /// without making or uploading anything twice. Files still staging there are placed here.
    func carryDraft(from previous: NewChatViewModel) {
        guard !retired, previous !== self else { return }
        attachments = previous.attachments
        prompt = previous.prompt
        caret = previous.caret
        if let shell = previous.startedShell {
            startedShell = shell
            saved = previous.saved
            // The chat works where it was made.
            if standalone, previous.standalone { folder = previous.folder }
        }
        staging += previous.staging
        previous.successor = self
    }

    func requestFocus() { if !retired { focusRequest &+= 1 } }
}

extension NewChatViewModel: ChatComposing {
    /// Files can be added until Start is under way.
    var canAttach: Bool { !retired && !busy }
    func edit(_ text: String, files: [ChatAttachment], caret: Int?) {
        guard !retired else { return }
        if attachments != files { attachments = files }
        if prompt != text { prompt = text }
        if self.caret != caret { self.caret = caret }
    }

    /// Places files at the caret, or at the end with no caret; a file already in the message is
    /// not placed twice.
    func attach(_ files: [ChatAttachment]) {
        guard canAttach, let placed = ChatCompletion.placing(files, in: prompt, files: attachments, caret: caret) else { return }
        attachments = placed.files
        prompt = placed.text
        caret = placed.caret
    }

    func attach(when files: @escaping @MainActor () async -> [ChatAttachment]) {
        guard canAttach else { return }
        staging += 1
        // Held until its files are ready, so a form retired meanwhile can still hand them on.
        Task { @MainActor in
            let ready = await files()
            // A form retired for one made anew hands its files on: the count went with them.
            var form = self
            while form.retired, let next = form.successor { form = next }
            form.staging -= 1
            form.attach(ready)
        }
    }

    /// Start's composers complete nothing: the suggestion keys and Escape take the protocol's
    /// defaults, so Escape goes on to what holds them.
    func submit() async { await start() }
}

/// How Start's first message carries its files: images as attachments, the rest as `@path` text.
enum ChatFirstMessage {
    /// Synara's limits on a turn (`PROVIDER_SEND_TURN_MAX_*`): what a message may carry, and the
    /// largest image read to be made small enough (`PROVIDER_SEND_TURN_MAX_IMAGE_IMPORT_BYTES`).
    static let maxImages = 8
    static let maxImageBytes = 10 * 1024 * 1024
    static let maxImportBytes = 32 * 1024 * 1024
    /// The image types every chat agent takes; another image is sent as PNG when it can be read.
    static var sentImageTypes: Set<String> { ChatImageTypes.sent }
    /// The sent types made smaller when too large, as Synara's `AUTOMATICALLY_OPTIMIZABLE_IMAGE_TYPES`;
    /// an image converted first is made smaller too. A GIF, which would lose its frames, is not.
    private static let optimizableTypes: Set<String> = ["image/jpeg", "image/png", "image/webp"]

    enum Part: Sendable {
        /// Saved and carried in `message.attachments`; its mark leaves the text.
        case image(ChatAttachment, name: String, mimeType: String, data: Data)
        /// Named in the text where its mark was; `path` is unescaped and absolute.
        case mention(ChatAttachment, path: String)
        /// An image an earlier Start already saved for the chat: the saved copy goes, its mark
        /// leaves the text, and the file is not read again.
        case saved(ChatAttachment)
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Each file's part, in order. An image already saved (`saved`) is not read again. Throws,
    /// naming the file, for an image too large, too many images, or a file that cannot be read.
    /// An image's size is checked, where a link to it leads, before it is read; one over
    /// `maxImageBytes` is drawn smaller and sent as JPEG, as Synara's composer does.
    static func read(_ files: [ChatAttachment], saved: Set<ChatAttachment.ID> = []) async throws -> [Part] {
        try await Task.detached(priority: .userInitiated) {
            var parts: [Part] = []
            var images = 0
            for file in files {
                let path = ChatAttachmentReader.unescape(file.path)
                if saved.contains(file.id) {
                    // Uploaded by an earlier Start: what is sent is the saved copy, not the file.
                    images += 1
                    parts.append(.saved(file))
                    continue
                }
                var isFolder: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) else {
                    throw Failure(message: String(localized: "‘\(file.name)’ can no longer be found."))
                }
                // The type of the file a link leads to, as the chat page takes it (`ChatPagePick`).
                let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
                let type = (try? resolved.resourceValues(forKeys: [.contentTypeKey]))?.contentType
                    ?? UTType(filenameExtension: resolved.pathExtension)
                guard !isFolder.boolValue, let type, type.conforms(to: .image) else {
                    parts.append(.mention(file, path: path)); continue
                }
                guard let image = try image(file, path: path, mimeType: type.preferredMIMEType ?? "") else {
                    // An image that is no bitmap (SVG): the agent reads it by its path.
                    parts.append(.mention(file, path: path)); continue
                }
                images += 1
                guard images <= maxImages else {
                    throw Failure(message: String(localized: "A message can carry up to \(maxImages) images."))
                }
                parts.append(.image(file, name: image.name, mimeType: image.mimeType, data: image.data))
            }
            return parts
        }.value
    }

    /// The image as it is sent: as it is when an agent takes its type and it is small enough;
    /// else converted to PNG, and drawn smaller as a JPEG when that is still too large. Nil for
    /// an image of another type that holds no bitmap.
    private static func image(_ file: ChatAttachment, path: String,
                              mimeType: String) throws -> (name: String, mimeType: String, data: Data)? {
        let converted = !sentImageTypes.contains(mimeType)
        let data = try boundedContents(of: file, at: path)
        var name = file.name, type = mimeType, bytes = data
        if converted, data.count <= maxImageBytes {
            // TIFF, HEIC and the like go as PNG.
            guard let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else { return nil }
            name = renamed(name, to: "png")
            type = "image/png"
            bytes = png
        }
        guard bytes.count > maxImageBytes else { return (name, type, bytes) }
        guard converted || optimizableTypes.contains(mimeType) else { throw tooLarge(file, limit: maxImageBytes) }
        let optimized: Data
        do {
            // From the file's own bytes: a converted copy would only be decoded again.
            optimized = try ChatImageOptimizer.optimize(data).data
        } catch ChatImageOptimizer.Failure.tooManyPixels {
            throw Failure(message: String(localized: "‘\(file.name)’ has too many pixels to be made small enough to send."))
        } catch {
            if converted { return nil }
            throw unreadable(file)
        }
        guard optimized.count <= maxImageBytes else { throw tooLarge(file, limit: maxImageBytes) }
        return (renamed(file.name, to: "jpg"), "image/jpeg", optimized)
    }

    /// The file's bytes, measured first where a link to it leads, and read no further than
    /// `maxImportBytes`: a file larger, or one that grew past it since, is refused.
    private static func boundedContents(of file: ChatAttachment, at path: String) throws -> Data {
        let target = (path as NSString).resolvingSymlinksInPath
        guard let size = (try? FileManager.default.attributesOfItem(atPath: target)[.size] as? NSNumber)?.intValue else {
            throw unreadable(file)
        }
        guard size <= maxImportBytes else { throw tooLarge(file, limit: maxImportBytes) }
        guard let handle = FileHandle(forReadingAtPath: target) else { throw unreadable(file) }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxImportBytes + 1) else { throw unreadable(file) }
        guard data.count <= maxImportBytes else { throw tooLarge(file, limit: maxImportBytes) }
        return data
    }

    private static func renamed(_ name: String, to pathExtension: String) -> String {
        ((name as NSString).deletingPathExtension as NSString).appendingPathExtension(pathExtension) ?? name
    }

    private static func unreadable(_ file: ChatAttachment) -> Failure {
        Failure(message: String(localized: "‘\(file.name)’ could not be read."))
    }

    private static func tooLarge(_ file: ChatAttachment, limit: Int) -> Failure {
        Failure(message: String(localized: "‘\(file.name)’ is larger than the \(limit / (1024 * 1024)) MB an image may be."))
    }

    /// The message's text: `draft` with each mention's mark replaced by its `@path`, set off by
    /// spaces from the words beside it, and each image's mark taken out, leaving a space where
    /// it parted two words.
    static func text(_ draft: String, parts: [Part]) -> String {
        var result = ""
        var next = 0
        var spaceBefore = false
        for character in draft {
            guard character == ChatCompletion.fileMark else {
                if spaceBefore, !character.isWhitespace { result.append(" ") }
                spaceBefore = false
                result.append(character)
                continue
            }
            defer { next += 1 }
            guard next < parts.count, case .mention(_, let path) = parts[next] else {
                if let last = result.last, !last.isWhitespace { spaceBefore = true }
                continue
            }
            if let last = result.last, !last.isWhitespace { result.append(" ") }
            result += mention(path)
            spaceBefore = true
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `@path`, or `@"path"` when it holds a space or anything a mention would stop at: Synara's
    /// `formatComposerMentionToken`, so the page reads it as the mention it would have written.
    static func mention(_ path: String) -> String {
        let quoted = path.unicodeScalars.contains { scalar in
            CharacterSet.whitespacesAndNewlines.contains(scalar) || "()@\"'`$\\".unicodeScalars.contains(scalar)
        }
        if !quoted, !path.isEmpty { return "@" + path }
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "@\"" + escaped + "\""
    }
}
