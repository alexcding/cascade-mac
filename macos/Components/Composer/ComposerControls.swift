import AppKit
import SwiftUI

// Start's composer, in pieces: the tray of chips along the card's top, the card with its field, the
// agent menu and the Start button under it, and the message line beneath. New Task's Start
// (`ProjectComposerView`) and a pane's Chat tab (`PaneChatComposer`) are both built from them.

/// The chips' tray: a row of chips along the top of `card`, on a soft fill, as the card's own header.
struct ComposerTray<Chips: View, Card: View>: View {
    @ViewBuilder let chips: Chips
    @ViewBuilder let card: Card

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) { chips }
                .padding(.horizontal, 8).padding(.vertical, 5)
            card
        }
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.surfaceHover))
    }
}

/// The field's card: the field over a row of controls, raised off the tray.
struct ComposerCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.border))
            .shadow(color: .black.opacity(0.06), radius: 12, y: 3)
    }
}

/// The message line under the tray. It is always there, so the page never moves as one comes and goes.
struct ComposerMessageLine<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ZStack(alignment: .leading) { content }
            .font(.system(size: 12)).lineLimit(2)
            .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
            .padding(.horizontal, 10)
    }
}

/// The composer's field. Return alone submits; with any modifier held — Shift, Option, Control or
/// Command — it is a new line: the field editor's own, at the cursor.
struct ComposerTextField: View {
    let placeholder: String
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var disabled = false
    let identifier: String
    let submit: () -> Void

    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .textFieldStyle(.plain).font(.system(size: 15)).lineLimit(2...10)
            .frame(minHeight: 44, alignment: .topLeading)
            .focused(focused).disabled(disabled)
            .onSubmit(submit)
            .onKeyPress(.return, phases: .down) { press in
                guard !press.modifiers.subtracting([.capsLock, .numericPad]).isEmpty else { return .ignored }
                NSApp.sendAction(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil)
                return .handled
            }
            .accessibilityIdentifier(identifier)
    }
}

/// Start: the round arrow at the card's corner.
struct ComposerStartButton: View {
    let enabled: Bool
    /// Its tooltip and accessibility label.
    let label: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // Start's own colour is the text's, not the accent: black on a light page, white on a dark one.
            Image(systemName: "arrow.up").font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.onProminent)
                .frame(width: 32, height: 32)
                .background(Circle().fill(enabled ? Theme.prominent : Color(nsColor: .tertiaryLabelColor)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

/// The card's agent menu: the agent's mark, its model and effort, opening `chooser` under it.
struct ComposerAgentButton<Chooser: View>: View {
    let agent: SessionAgent
    let title: String
    var detail: String?
    let help: String
    let identifier: String
    /// The popover; it is handed what closes it.
    @ViewBuilder let chooser: (_ close: @escaping () -> Void) -> Chooser
    @State private var open = false
    @State private var hovering = false

    var body: some View {
        let open = $open
        Button { open.wrappedValue.toggle() } label: {
            HStack(spacing: 6) {
                StartAgentMark(agent: agent)
                Text(title).foregroundStyle(.primary).lineLimit(1)
                if let detail { Text(detail).foregroundStyle(.secondary).lineLimit(1) }
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .font(.system(size: 14))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(open.wrappedValue || hovering ? Theme.surfaceHover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).fixedSize()
        .onHover { hovering = $0 }
        .popover(isPresented: open, arrowEdge: .bottom) { chooser { open.wrappedValue = false } }
        .help(help)
        .accessibilityIdentifier(identifier)
    }
}

/// One of the quiet controls over Start's field: a symbol and a name, on a soft fill under the
/// pointer or while what it opens is open.
struct ComposerChip: View {
    let symbol: String
    let title: String
    var chevron = false
    var active = false
    var interactive = true
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 13))
            // Capped, not framed: a `.frame(maxWidth:)` takes the whole 220 whenever it is offered it.
            WidthCap(limit: 220) { Text(title).lineLimit(1).truncationMode(.middle) }
            if chevron { Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary) }
        }
        .font(.system(size: 14))
        .foregroundStyle(Color.primary.opacity(0.85))
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(interactive && (active || hovering) ? Theme.border : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// Its one view at its own width, but never wider than `limit`: a longer one is offered `limit` and truncates.
private struct WidthCap: Layout {
    let limit: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(ProposedViewSize(width: min(proposal.width ?? .infinity, limit), height: proposal.height)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// An agent's own mark, in its colour; a shell's is the terminal symbol.
struct StartAgentMark: View {
    let agent: SessionAgent
    var body: some View {
        if agent == .shell {
            Image(systemName: "terminal").font(.system(size: 13)).foregroundStyle(.secondary)
        } else {
            AgentMark(key: agent.rawValue, size: 16)
        }
    }
}

/// One of an agent chooser's tabs: its mark and name, filled while chosen or under the pointer.
/// `unavailable` is why it cannot be chosen, when it cannot.
struct AgentTab: View {
    let agent: SessionAgent
    let selected: Bool
    var unavailable: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                StartAgentMark(agent: agent)
                Text(agent == .shell ? SessionAgent.shell.label : agent.driver?.shortName ?? agent.label)
                    .font(.system(size: 13.5, weight: selected ? .semibold : .regular)).lineLimit(1)
            }
            .frame(maxWidth: .infinity).frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Theme.surfaceHover : hovering ? Theme.surfaceHover.opacity(0.5) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .disabled(unavailable != nil)
        .opacity(unavailable == nil ? 1 : 0.5)
        .help(unavailable ?? "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A model or an effort: its full name, and a check on the one chosen.
struct ChoiceRow: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 14)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary).opacity(selected ? 1 : 0)
            }
            .padding(.horizontal, 10).frame(minHeight: 32)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected || hovering ? Theme.surfaceHover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A row of Start's pickers: an icon and a name, filled under the pointer and when it is the one
/// picked; `accessory` trails it.
struct PickerRow<Icon: View>: View {
    let title: String
    var selected = false
    let icon: Icon
    var accessory: AnyView?
    let action: () -> Void
    @State private var hovering = false

    init(title: String, selected: Bool = false, accessory: AnyView? = nil, @ViewBuilder icon: () -> Icon,
         action: @escaping () -> Void) {
        self.title = title; self.selected = selected; self.accessory = accessory; self.icon = icon(); self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon.frame(width: 18)
                Text(title).font(.system(size: 14)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if let accessory { accessory }
            }
            .padding(.horizontal, 10).frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected || hovering ? Theme.surfaceHover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension PickerRow where Icon == AnyView {
    init(symbol: String, title: String, selected: Bool = false, action: @escaping () -> Void) {
        self.init(title: title, selected: selected, icon: {
            AnyView(Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(.secondary))
        }, action: action)
    }
}
