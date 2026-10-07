import Foundation
import JavaScriptCore

/// A model's traits as the chat page's picker footer draws them: the effort ladder and where it
/// stands, speed, thinking, and the context window (Synara's `getComposerTraitSelection`).
struct ChatModelTraits: Decodable, Equatable, Sendable {
    struct Level: Decodable, Equatable, Sendable, Identifiable {
        let value: String
        let label: String
        var id: String { value }
    }
    var effortLevels: [Level] = []
    var effort: String?
    var defaultEffort: String?
    var ladderIndex = 0
    var statusLabel: String?
    /// Ultrathink in the prompt pins the ladder.
    var locked = false
    var supportsFastMode = false
    var fastModeEnabled = false
    var thinkingEnabled: Bool?
    var contextId: String?
    var contextLabel: String?
    var contextOptions: [Level] = []
    var contextWindow: String?
    var defaultContextWindow: String?
}

/// A model's effort ladder and default level, as the page's footer would offer them.
struct ChatModelLadder: Decodable, Equatable, Sendable {
    var levels: [ChatModelTraits.Level] = []
    var defaultEffort: String?
}

/// What the chat page's picker shows for a provider's models, for the app's own pickers to show
/// the same: Synara's catalogue merged with what the CLI reported, and each model's traits with
/// the option changes its controls commit, in Synara's own code. The page's build writes that
/// code beside the page as `ChatModelCatalog.js` (`macos/web/chat/src/modelCatalog.ts`), and this
/// runs it in JavaScriptCore, with no page, window, network or backend in its reach.
actor ChatModelCatalog {
    /// On the script in the app's bundle; a build without it (the unit tests') lists nothing, and
    /// the CLI's list stands.
    static let shared = ChatModelCatalog(script: bundledScript)

    private let script: URL?
    private var catalog: JSValue?
    private var failed = false

    init(script: URL?) { self.script = script }

    nonisolated static var bundledScript: URL? {
        let bundle = Bundle(for: ChatPageAssets.self)
        // A synchronized resource folder may or may not keep its directory in the bundle.
        return bundle.url(forResource: "ChatModelCatalog", withExtension: "js", subdirectory: "ChatPage")
            ?? bundle.url(forResource: "ChatModelCatalog", withExtension: "js")
    }

    /// The models for `provider`, as the page lists them given `runtime`, what the CLI reported
    /// (`provider.listModels`): in the page's order, under the page's names, Synara's default
    /// marked. Nil when the script cannot be run, for the caller to fall back on the CLI's list.
    func list(provider: String, runtime: [ChatModelOption]) -> [ChatModelOption]? {
        guard let listed: [ChatModelOption] = call("list", provider, text(descriptors(of: runtime))) else { return nil }
        let preferred = catalog?.invokeMethod("defaultModel", withArguments: [provider])
        let defaultSlug = preferred?.isString == true ? preferred?.toString() : nil
        return listed.map { option in
            var option = option
            option.isDefault = option.slug == defaultSlug
            return option
        }
    }

    /// Every listed model's ladder, by slug: what the page's footer would offer for each.
    func ladders(provider: String, runtime: [ChatModelOption]) -> [String: ChatModelLadder]? {
        call("ladders", provider, text(descriptors(of: runtime)))
    }

    /// `model`'s traits running with `options`, the provider's model options (`{}` for none).
    func traits(provider: String, model: String, runtime: [ChatModelOption], options: JSONValue) -> ChatModelTraits? {
        call("traits", provider, model, text(descriptors(of: runtime)), text(options))
    }

    /// `options` with the effort set to `value`; nil for a level the page sets through the prompt.
    func setEffort(provider: String, model: String, runtime: [ChatModelOption], options: JSONValue, value: String) -> JSONValue? {
        call("setEffort", provider, model, text(descriptors(of: runtime)), text(options), value)
    }

    /// `options` with `patch` laid over: speed, thinking, the context window.
    func setTrait(provider: String, options: JSONValue, patch: JSONValue) -> JSONValue? {
        call("setTrait", provider, text(options), text(patch))
    }

    /// `options` back at the model's default effort and standard speed.
    func resetTraits(provider: String, model: String, runtime: [ChatModelOption], options: JSONValue) -> JSONValue? {
        call("resetTraits", provider, model, text(descriptors(of: runtime)), text(options))
    }

    // MARK: The script

    /// The CLI's descriptors as it gave them, or the little the app knows of a model it did not.
    private func descriptors(of runtime: [ChatModelOption]) -> JSONValue {
        .array(runtime.map { option in
            option.descriptor ?? ["slug": .string(option.slug), "name": .string(option.title)]
        })
    }

    private func text(_ value: JSONValue) -> String { value.jsonText }

    /// Calls the script's `method` with `arguments`, decoding the JSON it answers; nil when it
    /// cannot run, throws, or answers null.
    private func call<T: Decodable>(_ method: String, _ arguments: String...) -> T? {
        guard let catalog = load(),
              let output = catalog.invokeMethod(method, withArguments: arguments), output.isString,
              let value = try? JSONDecoder().decode(T.self, from: Data(output.toString().utf8)) else { return nil }
        return value
    }

    private func load() -> JSValue? {
        if let catalog { return catalog }
        guard !failed, let script, let script = try? String(contentsOf: script, encoding: .utf8), let context = JSContext() else {
            failed = true
            return nil
        }
        var exception: String?
        context.exceptionHandler = { _, value in exception = value?.toString() }
        context.evaluateScript(script)
        guard exception == nil, let value = context.objectForKeyedSubscript("cascadeModelCatalog"), value.isObject else {
            failed = true
            return nil
        }
        catalog = value
        return value
    }
}
