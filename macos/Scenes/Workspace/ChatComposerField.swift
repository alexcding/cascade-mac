import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The chat's message field: text with each attached file placed in it as a chip. It is AppKit
/// because SwiftUI's field has no caret to complete at, no say over the keys a suggestion list
/// takes, and no paste or drop of its own; this one handles all three itself, so nothing listens
/// to the whole app's keys on its behalf.
///
/// The model holds the message; the field shows it and reports every edit back. A chip is one
/// character, so Backspace, Cut, or Select All then Delete take its file out of the message, and
/// Undo puts it back.
struct ChatComposerField: NSViewRepresentable {
    let chat: TranscriptChatModel
    // Passed in, not read off `chat` here, so the view that owns this one updates it when they change.
    let text: String
    let files: [ChatAttachment]
    let caret: Int?
    let focusRequest: Int
    /// The chat is the one on screen. A field still hidden cannot take the keyboard.
    let active: Bool
    let placeholder: String
    @Binding var dropTargeted: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ComposerScrollView {
        let view = ComposerScrollView(frame: .zero)
        view.textView.delegate = context.coordinator
        view.textView.composer = context.coordinator
        context.coordinator.textView = view.textView
        return view
    }

    func updateNSView(_ view: ComposerScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        view.textView.placeholder = placeholder
        coordinator.show(text: text, files: files, caret: caret)
        if active, focusRequest != coordinator.focusHandled {
            coordinator.focusHandled = focusRequest
            // After this update: the pass that shows the chat unhides it, and a hidden field
            // cannot take the keyboard.
            DispatchQueue.main.async { [weak textView = view.textView] in
                guard let textView, let window = textView.window else { return }
                window.makeFirstResponder(textView)
            }
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatComposerField?
        weak var textView: ComposerTextView?
        var focusHandled = Int.min
        /// Set while the model's message is being put in the field, which is not an edit to report.
        private var applying = false

        private var chat: TranscriptChatModel? { parent?.chat }

        /// Puts the model's message in the field when it is not what the field holds: after a
        /// send, a completion, or files placed from outside the field. As one undoable change.
        func show(text: String, files: [ChatAttachment], caret: Int?) {
            guard let textView, let storage = textView.textStorage else { return }
            let current = ChatComposerField.content(of: storage)
            guard current.text != text || current.files.map(\.id) != files.map(\.id) else { return }
            applying = true
            defer { applying = false }
            let replacement = ChatComposerField.attributed(text, files: files)
            let whole = NSRange(location: 0, length: storage.length)
            if textView.shouldChangeText(in: whole, replacementString: replacement.string) {
                storage.replaceCharacters(in: whole, with: replacement)
                textView.didChangeText()
            }
            textView.setSelectedRange(NSRange(location: min(caret ?? storage.length, storage.length), length: 0))
            textView.typingAttributes = ComposerTextView.attributes
            (textView.enclosingScrollView as? ComposerScrollView)?.textChanged()
        }

        private func report() {
            guard !applying, let chat, let textView, let storage = textView.textStorage else { return }
            let content = ChatComposerField.content(of: storage)
            let selection = textView.selectedRange()
            let caret = selection.length == 0 ? min(selection.location, (content.text as NSString).length) : nil
            chat.edit(content.text, files: content.files, caret: caret)
        }

        func textDidChange(_ notification: Notification) {
            report()
            (textView?.enclosingScrollView as? ComposerScrollView)?.textChanged()
        }

        func textViewDidChangeSelection(_ notification: Notification) { report() }

        /// Return sends and Shift- or Option-Return starts a new line. While the suggestion list
        /// is up, the arrows move in it, Tab and Return take a row, and Escape closes it.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let chat else { return false }
            let listed = !chat.suggestions.isEmpty
            switch selector {
            case #selector(NSResponder.moveUp(_:)) where listed:
                chat.moveHighlight(-1)
            case #selector(NSResponder.moveDown(_:)) where listed:
                chat.moveHighlight(1)
            case #selector(NSResponder.insertTab(_:)):
                // A tab typed into the terminal would ask the agent to complete, so it never goes in the text.
                if listed { Task { await chat.acceptSuggestion() } } else { textView.window?.selectNextKeyView(nil) }
            case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.complete(_:)):
                // Never the system's word completion, which Escape opens in a text view.
                if listed { chat.dismissSuggestions() }
            case #selector(NSResponder.insertNewline(_:)):
                if listed {
                    Task { await chat.acceptSuggestion(run: true) }
                } else if !(NSApp.currentEvent?.modifierFlags.intersection([.shift, .option]).isEmpty ?? true) {
                    textView.insertText("\n", replacementRange: textView.selectedRange())
                } else {
                    Task { await chat.send() }
                }
            case #selector(NSResponder.insertLineBreak(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                // A plain newline: a line separator would reach the terminal as a character of its own.
                textView.insertText("\n", replacementRange: textView.selectedRange())
            default:
                return false
            }
            return true
        }

        /// Copied files and screenshots become chips at the caret; text pastes as plain text.
        func pasteFiles(from pasteboard: NSPasteboard) -> Bool {
            guard let chat, ChatAttachmentReader.carriesFiles(pasteboard) else { return false }
            // A held message keeps its own files: nothing is added until it is sent or cancelled.
            guard chat.canAttach else { NSSound.beep(); return true }
            report()
            return ChatAttachmentReader.paste(from: pasteboard, into: chat)
        }

        func carriesFiles(_ pasteboard: NSPasteboard) -> Bool {
            (chat?.canAttach ?? false) && ChatAttachmentReader.carriesFiles(pasteboard)
        }

        func setDropTargeted(_ targeted: Bool) {
            if parent?.dropTargeted != targeted { parent?.dropTargeted = targeted }
        }
    }
}

extension ChatComposerField {
    /// The field's content as the model holds it: text with one mark per file, and the files in
    /// order. A mark with no file behind it (an image dropped some other way) is left out, and so
    /// is a second copy of a chip already in the message.
    static func content(of storage: NSAttributedString) -> (text: String, files: [ChatAttachment]) {
        var text = ""
        var files: [ChatAttachment] = []
        let string = storage.string as NSString
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            let piece = string.substring(with: range)
            let chip = value as? ChatFileAttachment
            for character in piece {
                guard character == ChatCompletion.fileMark else { text.append(character); continue }
                guard let chip, !files.contains(where: { $0.id == chip.file.id }) else { continue }
                text.append(character)
                files.append(chip.file)
            }
        }
        return (text, files)
    }

    static func attributed(_ text: String, files: [ChatAttachment]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var run = ""
        var next = 0
        for character in text {
            guard character == ChatCompletion.fileMark else { run.append(character); continue }
            if !run.isEmpty { result.append(NSAttributedString(string: run, attributes: ComposerTextView.attributes)); run = "" }
            guard next < files.count else { continue }
            let chip = NSMutableAttributedString(attachment: ChatFileAttachment(file: files[next]))
            chip.addAttributes(ComposerTextView.attributes, range: NSRange(location: 0, length: chip.length))
            result.append(chip)
            next += 1
        }
        if !run.isEmpty { result.append(NSAttributedString(string: run, attributes: ComposerTextView.attributes)) }
        return result
    }
}

/// Grows with its text from one line to ten, then scrolls.
final class ComposerScrollView: NSScrollView {
    let textView: ComposerTextView
    /// A text view built on its own text system does not keep its storage; this does.
    private let storage: NSTextStorage
    private var measuredWidth: CGFloat = -1
    private static let maxLines: CGFloat = 10

    override init(frame frameRect: NSRect) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        self.storage = storage
        textView = ComposerTextView(frame: .zero, textContainer: container)
        super.init(frame: frameRect)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        documentView = textView
        textView.configure()
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: textHeight)
    }

    private var lineHeight: CGFloat {
        ceil(textView.layoutManager?.defaultLineHeight(for: ComposerTextView.font) ?? 17)
    }

    private var textHeight: CGFloat {
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return lineHeight }
        layout.ensureLayout(for: container)
        let used = ceil(layout.usedRect(for: container).height)
        return min(max(used, lineHeight), lineHeight * Self.maxLines)
    }

    func textChanged() {
        invalidateIntrinsicContentSize()
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    override func layout() {
        super.layout()
        // Wrapping depends on the width, so a new width can mean a new height.
        if contentSize.width != measuredWidth {
            measuredWidth = contentSize.width
            invalidateIntrinsicContentSize()
        }
    }
}

final class ComposerTextView: NSTextView {
    weak var composer: ChatComposerField.Coordinator?
    var placeholder = "" {
        didSet {
            guard placeholder != oldValue else { return }
            setAccessibilityPlaceholderValue(placeholder)
            needsDisplay = true
        }
    }

    static let font = NSFont.systemFont(ofSize: 14)
    static var attributes: [NSAttributedString.Key: Any] { [.font: font, .foregroundColor: NSColor.labelColor] }

    func configure() {
        // Rich only for its chips: pasted text arrives plain.
        isRichText = true
        importsGraphics = false
        allowsImageEditing = false
        allowsUndo = true
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainerInset = .zero
        drawsBackground = false
        font = Self.font
        textColor = .labelColor
        typingAttributes = Self.attributes
        smartInsertDeleteEnabled = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        usesFindBar = false
        setAccessibilityIdentifier("transcript-chat-message")
        registerForDraggedTypes(registeredDraggedTypes + [.fileURL, .tiff, .png])
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText(), !placeholder.isEmpty else { return }
        (placeholder as NSString).draw(at: NSPoint(x: textContainerInset.width, y: textContainerInset.height),
                                       withAttributes: [.font: Self.font, .foregroundColor: NSColor.placeholderTextColor])
    }

    override func didChangeText() {
        super.didChangeText()
        // The placeholder comes and goes with the first character.
        needsDisplay = true
    }

    override func paste(_ sender: Any?) {
        if composer?.pasteFiles(from: .general) == true { return }
        pasteAsPlainText(sender)
    }

    // Files dragged in land as chips where they are dropped; anything else drops as text would.

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard composer?.carriesFiles(sender.draggingPasteboard) == true else { return super.draggingEntered(sender) }
        composer?.setDropTargeted(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard composer?.carriesFiles(sender.draggingPasteboard) == true else { return super.draggingUpdated(sender) }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        composer?.setDropTargeted(false)
        super.draggingExited(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        composer?.setDropTargeted(false)
        guard let composer, composer.carriesFiles(sender.draggingPasteboard) else { return super.performDragOperation(sender) }
        let index = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        setSelectedRange(NSRange(location: index, length: 0))
        return composer.pasteFiles(from: sender.draggingPasteboard)
    }
}

/// A file in the message, drawn as a chip.
final class ChatFileAttachment: NSTextAttachment {
    let file: ChatAttachment

    @MainActor init(file: ChatAttachment) {
        self.file = file
        super.init(data: nil, ofType: nil)
        let chip = ChatFileChip(name: file.name)
        let size = chip.size
        // Drawn when shown, so its colours follow the appearance it is shown in.
        image = NSImage(size: size, flipped: false) { rect in
            MainActor.assumeIsolated { chip.draw(in: rect) }
            return true
        }
        // Across the baseline, centred on the text beside it.
        bounds = CGRect(x: 0, y: -5, width: size.width, height: size.height)
    }

    required init?(coder: NSCoder) { nil }
}

/// Icon and name in a rounded box, as wide as the name up to a limit.
struct ChatFileChip: Sendable {
    let name: String
    let symbol: String

    private static let height: CGFloat = 20
    private static let maxNameWidth: CGFloat = 180
    /// Room between a chip and the text either side of it.
    private static let margin: CGFloat = 2
    private static let icon: CGFloat = 14

    init(name: String) {
        self.name = name
        let isImage = UTType(filenameExtension: (name as NSString).pathExtension)?.conforms(to: .image) ?? false
        symbol = isImage ? "photo" : "doc"
    }

    private static var font: NSFont { NSFont.systemFont(ofSize: 12) }

    @MainActor private var nameWidth: CGFloat {
        min(ceil((name as NSString).size(withAttributes: [.font: Self.font]).width), Self.maxNameWidth)
    }

    @MainActor var size: NSSize {
        NSSize(width: Self.margin * 2 + 8 + Self.icon + 4 + nameWidth + 8, height: Self.height)
    }

    @MainActor func draw(in frame: NSRect) {
        let box = frame.insetBy(dx: Self.margin, dy: 1)
        let outline = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
        Theme.palette.surfaceHover.nsColor.setFill()
        outline.fill()
        Theme.palette.border.nsColor.setStroke()
        outline.lineWidth = 1
        outline.stroke()

        let tint = NSImage.SymbolConfiguration(paletteColors: [Theme.palette.textSecondary.nsColor])
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular).applying(tint)
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
            let size = image.size
            image.draw(in: NSRect(x: box.minX + 8 + (Self.icon - size.width) / 2, y: box.midY - size.height / 2,
                                  width: size.width, height: size.height))
        }

        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: NSColor.labelColor, .paragraphStyle: style]
        let lineHeight = ceil(Self.font.ascender - Self.font.descender)
        let rect = NSRect(x: box.minX + 8 + Self.icon + 4, y: box.midY - lineHeight / 2, width: nameWidth, height: lineHeight)
        (name as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
    }
}
