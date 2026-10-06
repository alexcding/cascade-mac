import AppKit
import Foundation
import Testing
@testable import Cascade

// Start's chat composers: files picked, pasted or dropped go with the first message — images saved
// and carried as attachments, every other file and folder named in the text by its path.

/// A chat service that keeps every call, saves attachments under ids of its own, and can refuse turns.
private final class AttachingChat: ChatServing, @unchecked Sendable {
    private let lock = NSLock()
    private var _commands: [JSONValue] = []
    private var _saves: [JSONValue] = []
    var commands: [JSONValue] { lock.withLock { _commands } }
    var saves: [JSONValue] { lock.withLock { _saves } }
    /// How many `thread.turn.start`s to refuse before taking one.
    var refusedTurns = 0
    /// Awaited before a save answers: a test holds an upload in flight with it.
    var holdSave: (@Sendable () async -> Void)?

    func rpc(_ method: String, params: JSONValue) async throws -> JSONValue {
        switch method {
        case "chat.providerStatuses":
            return [["provider": "claudeAgent", "available": true, "models": [["slug": "opus", "isDefault": true]]]]
        case "attachments.save":
            let count = lock.withLock { _saves.append(params); return _saves.count }
            await holdSave?()
            return ["type": "image", "id": .string("att-\(count)"), "name": params["name"] ?? .null,
                    "mimeType": params["mimeType"] ?? .null, "sizeBytes": 4]
        case "orchestration.dispatchCommand":
            let refused = lock.withLock {
                _commands.append(params["command"] ?? .null)
                guard params["command"]?["type"]?.string == "thread.turn.start", refusedTurns > 0 else { return false }
                refusedTurns -= 1
                return true
            }
            if refused { throw ChatRPCError(message: "Provider offline") }
            return ["sequence": 1]
        default: return .null
        }
    }
}

/// A folder of files to attach, removed with the test.
private final class Scratch {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("new-chat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func file(_ name: String, _ data: Data = Data("text".utf8)) throws -> URL {
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// A PNG of random pixels, which does not compress.
private func noisePNG(width: Int, height: Int) throws -> Data {
    let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                            samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: width * 3, bitsPerPixel: 24))
    let pixels = try #require(rep.bitmapData)
    arc4random_buf(pixels, width * height * 3)
    return try #require(rep.representation(using: .png, properties: [:]))
}

@MainActor private func form(_ service: AttachingChat) async -> NewChatViewModel {
    let model = NewChatViewModel(projectID: nil, projectName: nil, folder: "", service: service, agent: "claude")
    await model.load()
    return model
}

@MainActor struct NewChatAttachmentTests {
    @Test func imagesAreSavedAndCarriedWhileFilesAndFoldersAreNamedByPath() async throws {
        let scratch = try Scratch(), service = AttachingChat()
        let image = try scratch.file("shot.png", Data([0x89, 0x50, 0x4E, 0x47]))
        let notes = try scratch.file("notes.txt")
        let folder = try scratch.folder("My Folder")
        let model = await form(service)
        model.prompt = "Look at "
        model.attach(ChatAttachmentReader.files([image, notes, folder]))
        model.prompt += " please"
        #expect(model.attachments.map(\.name) == ["shot.png", "notes.txt", "My Folder"])
        #expect(model.canStart)

        await model.start()
        #expect(model.error == nil)
        let commands = service.commands
        #expect(commands.compactMap { $0["type"]?.string } == ["thread.create", "thread.turn.start"])
        let thread = try #require(commands.first?["threadId"]?.string)

        let save = try #require(service.saves.first)
        #expect(service.saves.count == 1, "only the image is uploaded")
        #expect(save["threadId"]?.string == thread && save["name"]?.string == "shot.png" && save["mimeType"]?.string == "image/png")
        #expect(save["dataBase64"]?.string.flatMap { Data(base64Encoded: $0) } == Data([0x89, 0x50, 0x4E, 0x47]))

        let message = try #require(commands.last?["message"])
        #expect(message["attachments"] == [["type": "image", "id": "att-1", "name": "shot.png", "mimeType": "image/png", "sizeBytes": 4]])
        let text = try #require(message["text"]?.string)
        #expect(text == "Look at @\(notes.path) @\"\(folder.path)\" please", "the image's chip leaves the text")
        #expect(!text.contains(ChatCompletion.fileMark))
    }

    @Test func filesAloneStartAChat() async throws {
        let scratch = try Scratch(), service = AttachingChat()
        let notes = try scratch.file("notes.txt")
        let model = await form(service)
        #expect(!model.canStart)
        model.attach(ChatAttachmentReader.files([notes]))
        #expect(model.canStart, "a file is something to send")
        await model.start()
        #expect(service.commands.last?["message"]?["text"]?.string == "@\(notes.path)")
        #expect(service.commands.last?["message"]?["attachments"] == [])
    }

    @Test func aFailedFirstMessageKeepsItsDraftAndIsNotUploadedAgain() async throws {
        let scratch = try Scratch(), service = AttachingChat()
        service.refusedTurns = 1
        let image = try scratch.file("shot.png", Data([1, 2, 3, 4]))
        let model = await form(service)
        model.prompt = "What is this?"
        model.attach(ChatAttachmentReader.files([image]))
        let draft = model.prompt

        await model.start()
        #expect(model.error == "Provider offline" && !model.retired)
        #expect(model.prompt == draft && model.attachments.map(\.name) == ["shot.png"], "text and files stay")
        #expect(service.saves.count == 1)

        try FileManager.default.removeItem(at: image)
        var created = 0
        model.onAction = { if case .created = $0 { created += 1 } }
        await model.start()
        #expect(model.error == nil && created == 1)
        #expect(service.saves.count == 1, "the image saved the first time is not saved or read again")
        let turns = service.commands.filter { $0["type"]?.string == "thread.turn.start" }
        #expect(turns.count == 2 && service.commands.filter { $0["type"]?.string == "thread.create" }.count == 1)
        #expect(turns.last?["message"]?["attachments"]?.array?.first?["id"]?.string == "att-1")
        #expect(turns.last?["message"]?["text"]?.string == "What is this?")
    }

    @Test func anImageTooLargeMakesNoChatAndKeepsTheDraft() async throws {
        let scratch = try Scratch(), service = AttachingChat()
        let image = try scratch.file("huge.jpg", Data(count: ChatFirstMessage.maxImportBytes + 1))
        let model = await form(service)
        model.prompt = "Look"
        model.attach(ChatAttachmentReader.files([image]))
        await model.start()
        #expect(model.error?.contains("huge.jpg") == true && model.error?.contains("32 MB") == true)
        #expect(service.commands.isEmpty && service.saves.isEmpty, "nothing is made for a message that cannot go")
        #expect(model.attachments.map(\.name) == ["huge.jpg"] && ChatCompletion.text(of: model.prompt) == "Look")
    }

    @Test func aMissingFileIsReportedByName() async throws {
        let scratch = try Scratch(), service = AttachingChat()
        let notes = try scratch.file("gone.txt")
        let model = await form(service)
        model.attach(ChatAttachmentReader.files([notes]))
        try FileManager.default.removeItem(at: notes)
        await model.start()
        #expect(model.error?.contains("gone.txt") == true && service.commands.isEmpty)
    }

    @Test func mentionsAreQuotedOnlyWhenThePathNeedsIt() {
        #expect(ChatFirstMessage.mention("/Users/me/src/main.rs") == "@/Users/me/src/main.rs")
        #expect(ChatFirstMessage.mention("/Users/me/My Notes.md") == "@\"/Users/me/My Notes.md\"")
        #expect(ChatFirstMessage.mention("/tmp/a(1).txt") == "@\"/tmp/a(1).txt\"")
        #expect(ChatFirstMessage.mention("/tmp/a@2x.txt") == "@\"/tmp/a@2x.txt\"")
        #expect(ChatFirstMessage.mention("/tmp/v1,2:3+~.txt") == "@/tmp/v1,2:3+~.txt")
        #expect(ChatFirstMessage.mention("/tmp/say \"hi\".txt") == "@\"/tmp/say \\\"hi\\\".txt\"")
    }

    @Test func aChipBetweenWordsIsSetOffBySpaces() throws {
        let file = ChatAttachment(path: "/a.txt", name: "a.txt")
        let mark = String(ChatCompletion.fileMark)
        #expect(ChatFirstMessage.text("see\(mark)now", parts: [.mention(file, path: "/a.txt")]) == "see @/a.txt now")
        #expect(ChatFirstMessage.text("\(mark) see", parts: [.image(file, name: "a.png", mimeType: "image/png", data: Data())]) == "see")
        let image = ChatFirstMessage.Part.image(file, name: "a.png", mimeType: "image/png", data: Data())
        #expect(ChatFirstMessage.text("look\(mark)here", parts: [image]) == "look here", "an image's chip still parts two words")
        #expect(ChatFirstMessage.text("look \(mark) here", parts: [image]) == "look  here", "spaces typed are kept as typed")
    }

    @Test func aFormMadeAnewKeepsTheFiles() async throws {
        let service = AttachingChat()
        let model = await form(service)
        model.prompt = "Hi "
        model.attach([ChatAttachment(path: "/a.txt", name: "a.txt")])
        let next = NewChatViewModel(projectID: nil, projectName: nil, folder: "", service: service)
        next.carryDraft(from: model)
        #expect(next.prompt == model.prompt && next.attachments == model.attachments)
    }
}

@MainActor struct NewChatCarryAndLimitTests {
    @Test func aFormMadeAnewAfterAFailedStartSendsToTheSameChatWithoutUploadingAgain() async throws {
        let scratch = try Scratch(), service = AttachingChat()
        service.refusedTurns = 1
        let image = try scratch.file("shot.png", Data([1, 2, 3, 4]))
        let model = await form(service)
        model.prompt = "What is this?"
        model.attach(ChatAttachmentReader.files([image]))
        await model.start()
        #expect(model.error == "Provider offline" && service.saves.count == 1)

        // Reconnect: a new form takes the old one's place, as `NewSessionViewModel.showChat(again:)` does.
        let next = await form(service)
        next.carryDraft(from: model)
        model.retire()
        var created: ChatThreadShell?
        next.onAction = { if case .created(let shell) = $0 { created = shell } }
        await next.start()
        #expect(next.error == nil)
        let creates = service.commands.filter { $0["type"]?.string == "thread.create" }
        let turns = service.commands.filter { $0["type"]?.string == "thread.turn.start" }
        #expect(creates.count == 1, "the chat the failed Start made is the one sent to")
        #expect(service.saves.count == 1, "the image saved for it is not uploaded again")
        #expect(turns.count == 2 && turns.last?["threadId"] == creates.first?["threadId"])
        #expect(turns.last?["message"]?["attachments"]?.array?.first?["id"]?.string == "att-1")
        #expect(created?.id == creates.first?["threadId"]?.string)
    }

    @Test func aFileStillStagingWhenTheFormIsMadeAnewLandsInTheNewOne() async throws {
        let service = AttachingChat()
        let model = await form(service)
        let (gate, open) = AsyncStream<Void>.makeStream()
        model.attach(when: {
            for await _ in gate { break }
            return [ChatAttachment(path: "/shot.png", name: "shot.png")]
        })
        #expect(model.staging == 1)

        let next = await form(service)
        next.carryDraft(from: model)
        model.retire()
        #expect(next.staging == 1 && !next.canStart, "Start waits for the file the old form was staging")
        open.yield()
        for _ in 0..<200 where next.staging > 0 { await Task.yield() }
        #expect(next.staging == 0 && next.attachments.map(\.name) == ["shot.png"])
        #expect(model.attachments.isEmpty, "the retired form keeps nothing")
    }

    @Test func anImageIsMeasuredBeforeItIsRead() async throws {
        let scratch = try Scratch()
        // Unreadable, so a read would fail: only its size can refuse it.
        let image = try scratch.file("huge.png", Data(count: ChatFirstMessage.maxImportBytes + 1))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: image.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: image.path) }
        let file = try #require(ChatAttachmentReader.files([image]).first)
        await #expect(throws: ChatFirstMessage.Failure.self) { try await ChatFirstMessage.read([file]) }
        do { _ = try await ChatFirstMessage.read([file]) } catch {
            #expect(error.localizedDescription.contains("32 MB"), "refused for its size, not for being unreadable")
        }
    }

    @Test func aLinkToAnImageIsMeasuredWhereItLeads() async throws {
        let scratch = try Scratch()
        // The link itself is a few bytes; what it leads to is too large, and unreadable, so only
        // its size can refuse it.
        let target = try scratch.file("huge.bin", Data(count: ChatFirstMessage.maxImportBytes + 1))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: target.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path) }
        let link = scratch.root.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let file = try #require(ChatAttachmentReader.files([link]).first)
        do {
            _ = try await ChatFirstMessage.read([file])
            Issue.record("a link to an image too large was read")
        } catch {
            #expect(error.localizedDescription.contains("link.png") && error.localizedDescription.contains("32 MB"))
        }
    }

    @Test func anImageOverTheLimitIsDrawnSmallerAsJPEG() async throws {
        let scratch = try Scratch()
        // Noise does not compress: a PNG of it is well over 10 MB, and wider than an image is drawn.
        let image = try scratch.file("wide.png", noisePNG(width: 9_000, height: 1_000))
        #expect(try Data(contentsOf: image).count > ChatFirstMessage.maxImageBytes)
        let file = try #require(ChatAttachmentReader.files([image]).first)
        let parts = try await ChatFirstMessage.read([file])
        guard case .image(_, let name, let mimeType, let data) = parts.first else { Issue.record("expected an image"); return }
        #expect(name == "wide.jpg" && mimeType == "image/jpeg")
        #expect(data.count <= ChatFirstMessage.maxImageBytes)
        let rep = try #require(NSBitmapImageRep(data: data))
        #expect(max(rep.pixelsWide, rep.pixelsHigh) <= ChatImageOptimizer.maxRenderEdge)
        #expect(rep.pixelsWide * rep.pixelsHigh <= ChatImageOptimizer.maxRenderPixels)
    }

    @Test func anImageWithTooManyPixelsIsRefused() async throws {
        let scratch = try Scratch()
        // Wider than is decoded safely; padded past 10 MB so it would have to be made smaller.
        var data = try noisePNG(width: ChatImageOptimizer.maxSourceEdge + 1, height: 1)
        data.append(Data(count: ChatFirstMessage.maxImageBytes))
        let image = try scratch.file("tall.png", data)
        let file = try #require(ChatAttachmentReader.files([image]).first)
        do {
            _ = try await ChatFirstMessage.read([file])
            Issue.record("an image with too many pixels was sent")
        } catch {
            #expect(error.localizedDescription.contains("tall.png") && error.localizedDescription.contains("pixels"))
        }
    }

    @Test func anImageSavedAfterTheFormWasMadeAnewIsNotUploadedAgain() async throws {
        let scratch = try Scratch(), service = AttachingChat()
        let image = try scratch.file("shot.png", Data([1, 2, 3, 4]))
        let (gate, open) = AsyncStream<Void>.makeStream()
        let (arrived, arrive) = AsyncStream<Void>.makeStream()
        service.holdSave = { arrive.yield(); for await _ in gate { break } }
        let model = await form(service)
        model.prompt = "What is this?"
        model.attach(ChatAttachmentReader.files([image]))
        let first = Task { await model.start() }
        for await _ in arrived { break }

        // Reconnect while the upload is in flight.
        let next = await form(service)
        next.carryDraft(from: model)
        model.retire()
        service.holdSave = nil
        open.yield()
        await first.value
        #expect(service.saves.count == 1)

        await next.start()
        #expect(next.error == nil)
        let creates = service.commands.filter { $0["type"]?.string == "thread.create" }
        let turns = service.commands.filter { $0["type"]?.string == "thread.turn.start" }
        #expect(creates.count == 1 && service.saves.count == 1, "the upload that finished after the remake is used")
        #expect(turns.count == 1 && turns.first?["threadId"] == creates.first?["threadId"])
        #expect(turns.first?["message"]?["attachments"]?.array?.first?["id"]?.string == "att-1")
    }

    @Test func anImageToConvertIsBoundedBeforeItIsDecoded() async throws {
        let scratch = try Scratch()
        let image = try scratch.file("huge.tiff", Data(count: ChatFirstMessage.maxImportBytes + 1))
        let file = try #require(ChatAttachmentReader.files([image]).first)
        do {
            _ = try await ChatFirstMessage.read([file])
            Issue.record("an image too large to convert was read")
        } catch {
            #expect(error.localizedDescription.contains("huge.tiff") && error.localizedDescription.contains("32 MB"))
        }
    }

    @Test func anImageAlreadySavedIsNotReadAgain() async throws {
        let file = ChatAttachment(path: "/no/such/shot.png", name: "shot.png")
        let parts = try await ChatFirstMessage.read([file], saved: [file.id])
        guard case .saved(let saved) = parts.first else { Issue.record("expected a saved part"); return }
        #expect(saved == file && parts.count == 1)
        #expect(ChatFirstMessage.text("look\(ChatCompletion.fileMark)here", parts: parts) == "look here")
    }
}

/// Records whether Escape reached it, as a sheet or window holding the field would.
private final class EscapeCatcher: NSResponder {
    var caught = 0
    override func cancelOperation(_ sender: Any?) { caught += 1 }
}

/// A composer that keeps Escape or not, with a suggestion list up or not.
@MainActor private final class EscapeComposer: ChatComposing {
    var keeps: Bool
    var showsSuggestions: Bool
    var dismissed = 0
    var focusRequest = 0
    var focusTaken = 0
    init(keeps: Bool, listed: Bool) { self.keeps = keeps; showsSuggestions = listed }
    var canAttach: Bool { true }
    func requestFocus() { focusRequest += 1 }
    func edit(_ text: String, files: [ChatAttachment], caret: Int?) {}
    func attach(_ files: [ChatAttachment]) {}
    func attach(when files: @escaping @MainActor () async -> [ChatAttachment]) {}
    func submit() async {}
    func moveHighlight(_ step: Int) {}
    func dismissSuggestions() { dismissed += 1 }
    func cancel() -> Bool { dismissed += 1; return keeps }
    func acceptHighlighted(run: Bool) async {}
}

@MainActor struct ChatComposerEscapeTests {
    private func escape(_ chat: any ChatComposing) -> (handled: Bool, caught: Int) {
        let view = ComposerScrollView(frame: .zero)
        let catcher = EscapeCatcher()
        view.textView.nextResponder = catcher
        let coordinator = ChatComposerField.Coordinator()
        coordinator.parent = ChatComposerField(chat: chat, text: "", files: [], caret: nil, focusRequest: 0, active: true,
                                               placeholder: "", dropTargeted: .constant(false))
        coordinator.textView = view.textView
        let handled = coordinator.textView(view.textView, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        return (handled, catcher.caught)
    }

    @Test func startsComposersPassEscapeOn() async {
        let model = NewChatViewModel(projectID: nil, projectName: nil, folder: "", service: AttachingChat())
        let result = escape(model)
        #expect(result.handled, "never the text view's word completion")
        #expect(result.caught == 1, "Escape reaches what holds the field")
    }

    @Test func aComposerThatKeepsEscapeKeepsIt() {
        let chat = EscapeComposer(keeps: true, listed: false)
        let result = escape(chat)
        #expect(result.handled && result.caught == 0 && chat.dismissed == 1)
    }

    @Test func aSuggestionListTakesEscapeFirst() {
        let chat = EscapeComposer(keeps: false, listed: true)
        let result = escape(chat)
        #expect(result.handled && result.caught == 0 && chat.dismissed == 1)
    }
}
