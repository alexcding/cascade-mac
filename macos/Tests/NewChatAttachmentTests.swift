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

    func rpc(_ method: String, params: JSONValue) async throws -> JSONValue {
        switch method {
        case "chat.providerStatuses":
            return [["provider": "claudeAgent", "available": true, "models": [["slug": "opus", "isDefault": true]]]]
        case "attachments.save":
            let count = lock.withLock { _saves.append(params); return _saves.count }
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
        let image = try scratch.file("huge.jpg", Data(count: ChatFirstMessage.maxImageBytes + 1))
        let model = await form(service)
        model.prompt = "Look"
        model.attach(ChatAttachmentReader.files([image]))
        await model.start()
        #expect(model.error?.contains("huge.jpg") == true && model.error?.contains("10 MB") == true)
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
