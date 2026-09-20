import AppKit
import CodeEditLanguages
import CodeEditSourceEditor

// The file editor: CodeEditSourceEditor's tree-sitter text view behind the `EditorSurface`
// contract. Swift still owns the version counter, so saves acknowledge exactly what was submitted.
@MainActor final class CodeEditEditorSurface: NSObject, EditorSurface {
    private final class ChangeCoordinator: TextViewCoordinator {
        var textChanged: () -> Void = {}

        func prepareCoordinator(controller: TextViewController) {}
        func textViewDidChangeText(controller: TextViewController) { textChanged() }
        func destroy() { textChanged = {} }
    }

    private(set) var view: NSView?
    var changed: (Bool) -> Void = { _ in }
    var failed: (String) -> Void = { _ in }
    var saveRequested: () -> Void = {}

    private var controller: TextViewController?
    private var coordinator: ChangeCoordinator?
    private var appearanceObservation: NSKeyValueObservation?
    private var version = 1
    private var savedVersion = 1
    private var readOnly = false
    private var suppressChanges = false
    private var font = CodeFont(size: 12)
    private var style = EditorStyle()

    func load(_ value: FileDocumentSnapshot, path: String) async throws {
        let coordinator = ChangeCoordinator()
        coordinator.textChanged = { [weak self] in
            guard let self, !self.suppressChanges else { return }
            self.version += 1
            self.changed(self.version != self.savedVersion)
        }

        suppressChanges = true
        readOnly = value.readOnly
        let controller = TextViewController(
            string: value.content,
            language: CodeLanguage.detectLanguageFrom(url: URL(fileURLWithPath: path)),
            configuration: SourceEditorConfiguration(
                appearance: .init(theme: Self.theme(style, for: NSApp.effectiveAppearance),
                                  font: resolvedFont(),
                                  wrapLines: false),
                behavior: .init(isEditable: !readOnly),
                // Explicit zeros turn automatic insetting off: this editor sits under a tab bar, not
                // the title bar the scroll view would otherwise inset itself for.
                layout: .init(contentInsets: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)),
                peripherals: .init(showMinimap: style.showMinimap)
            ),
            cursorPositions: [],
            coordinators: [coordinator]
        )
        let hosted = controller.view
        // The gutter floats over the scroll view and would otherwise draw across the tab bar.
        hosted.clipsToBounds = true
        controller.scrollView.clipsToBounds = true
        controller.textView.setAccessibilityIdentifier("native-code-editor")
        version = 1
        savedVersion = 1
        suppressChanges = false

        self.controller = controller
        self.coordinator = coordinator
        view = hosted
        // `.system` follows the window, so the theme is rebuilt whenever that resolves anew.
        // Observed on the app, where the key path is documented as observable; the view inherits it.
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.applyTheme() }
        }
        installSaveShortcut()
    }

    // The package handles its own shortcuts in a local monitor and has no save hook. One monitor
    // serves every open file: it is installed with the first surface and removed with the last.
    private static var saveMonitor: Any?
    private static var live: [ObjectIdentifier: () -> CodeEditEditorSurface?] = [:]

    private func installSaveShortcut() {
        Self.live[ObjectIdentifier(self)] = { [weak self] in self }
        guard Self.saveMonitor == nil else { return }
        Self.saveMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "s",
                  let surface = Self.live.values.lazy.compactMap({ $0() }).first(where: \.isFocused) else { return event }
            surface.saveRequested()
            return nil
        }
    }

    private func removeSaveShortcut() {
        Self.live[ObjectIdentifier(self)] = nil
        guard Self.live.isEmpty, let monitor = Self.saveMonitor else { return }
        NSEvent.removeMonitor(monitor)
        Self.saveMonitor = nil
    }

    private var isFocused: Bool {
        guard let textView = controller?.textView, let window = textView.window else { return false }
        return window.isKeyWindow && window.firstResponder === textView
    }

    func snapshot(freeze: Bool) async throws -> EditorBuffer {
        guard let controller else { throw BackendError.operation("The editor is no longer available.") }
        if freeze { controller.configuration.behavior.isEditable = false }
        return EditorBuffer(content: controller.text, version: version, dirty: version != savedVersion)
    }

    func acknowledge(version: Int) async throws -> Bool {
        savedVersion = version
        return self.version != savedVersion
    }

    func unfreeze() async throws {
        controller?.configuration.behavior.isEditable = !readOnly
    }

    func setAppearance(_ value: AppAppearance) {
        guard let view else { return }
        switch value {
        case .light:
            view.appearance = NSAppearance(named: .aqua)
        case .dark:
            view.appearance = NSAppearance(named: .darkAqua)
        case .system:
            view.appearance = nil
        }
        applyTheme()
    }

    private func applyTheme() {
        guard let controller, let view else { return }
        let theme = Self.theme(style, for: view.effectiveAppearance)
        guard controller.configuration.appearance.theme != theme else { return }
        controller.configuration.appearance.theme = theme
    }

    func setFont(_ value: CodeFont) {
        font = value
        controller?.configuration.appearance.font = resolvedFont()
    }

    private func resolvedFont() -> NSFont {
        (font.family.isEmpty ? nil : NSFont(name: font.family, size: CGFloat(font.size)))
            ?? NSFont.monospacedSystemFont(ofSize: CGFloat(font.size), weight: .regular)
    }

    func focus(line: Int, column: Int) {
        guard let controller else { return }
        controller.setCursorPositions([CursorPosition(line: max(1, line), column: max(1, column))],
                                      scrollToVisible: true)
        controller.textView.window?.makeFirstResponder(controller.textView)
    }

    // The find panel is internal to the package; it opens from the package's own ⌘F handling,
    // which only listens while its text view is first responder.
    func find() {
        guard let textView = controller?.textView, let window = textView.window else { return }
        // Unfocused, the package lets ⌘F through to the Find menu item, which calls back in here.
        guard window.makeFirstResponder(textView), window.firstResponder === textView, window.isKeyWindow,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           characters: "f", charactersIgnoringModifiers: "f",
                                           isARepeat: false, keyCode: 3) else { return }
        NSApp.postEvent(event, atStart: true)
    }

    func setStyle(_ value: EditorStyle) {
        style = value
        applyTheme()
        guard let controller, controller.configuration.peripherals.showMinimap != value.showMinimap else { return }
        controller.configuration.peripherals.showMinimap = value.showMinimap
    }

    func dispose() {
        removeSaveShortcut()
        appearanceObservation = nil
        coordinator?.destroy()
        coordinator = nil
        controller = nil
        view?.removeFromSuperview()
        view = nil
        changed = { _ in }
        failed = { _ in }
        saveRequested = {}
    }

    // The package colours text once per theme, so colours are resolved for the appearance in force
    // rather than handed over as dynamic colours.
    private static func theme(_ style: EditorStyle, for appearance: NSAppearance) -> EditorTheme {
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let theme = style.theme(dark: dark)
        func resolve(_ color: NSColor) -> NSColor {
            var resolved = color
            appearance.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) ?? color }
            return resolved
        }
        func token(_ rgb: UInt32, italic: Bool = false) -> EditorTheme.Attribute {
            .init(color: CodeTheme.color(rgb), italic: italic)
        }
        let text = token(theme.text)
        return EditorTheme(
            text: text,
            insertionPoint: text.color,
            invisibles: token(theme.comment),
            background: theme.background.map(CodeTheme.color) ?? resolve(.textBackgroundColor),
            lineHighlight: CodeTheme.color(theme.selection).withAlphaComponent(0.35),
            selection: CodeTheme.color(theme.selection),
            keywords: token(theme.keyword),
            commands: token(theme.function),
            types: token(theme.type),
            attributes: token(theme.keyword),
            variables: text,
            values: token(theme.number),
            numbers: token(theme.number),
            strings: token(theme.string),
            characters: token(theme.string),
            comments: token(theme.comment, italic: true)
        )
    }
}
