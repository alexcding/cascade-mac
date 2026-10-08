import SwiftUI

// Automation's form controls, in the app's own look rather than the system's: a choice that opens
// the composer's floating list rather than a system pop-up, chips in place of a segmented control,
// and a grouped list for adding one of many. Text fields take `themedField` (`Theme`).

/// One of a choice's options: what it stands for and what it is called.
struct ThemedOption<Value: Hashable>: Hashable {
    let value: Value
    let label: String
    init(_ value: Value, _ label: String) { self.value = value; self.label = label }
}

/// A choice on a field's face, its value and a chevron; a click hangs the options under it, the
/// chosen one ticked, as the composer's model and effort lists do.
struct ThemedChoice<Value: Hashable>: View {
    let title: String
    let options: [ThemedOption<Value>]
    @Binding var selection: Value
    /// Shown when the selection is none of the options.
    var placeholder: String = ""
    @State private var open = false
    @State private var hovering = false

    var body: some View {
        let current = options.first { $0.value == selection }?.label
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                Text(current ?? placeholder).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(current == nil ? Theme.textTertiary : Color.primary)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textTertiary)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10).frame(height: Theme.Size.field)
            .fieldFace(active: open, hovering: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .floatingPanel(isPresented: $open) {
            ThemedChoiceList(options: options, selection: selection) { selection = $0; open = false }
        }
        .accessibilityLabel(title)
        .accessibilityValue(current ?? placeholder)
    }
}

/// A choice's open list, scrolled to the chosen one. The keyboard works it as a menu's: the arrows
/// move the highlight, Return takes it, and typing goes to the first option whose name starts so.
private struct ThemedChoiceList<Value: Hashable>: View {
    let options: [ThemedOption<Value>]
    let selection: Value
    let choose: (Value) -> Void
    @State private var highlighted: Int?
    @State private var typed = ""
    @State private var typedAt = Date.distantPast
    @FocusState private var focused: Bool

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                        ChoiceRow(title: option.label, selected: option.value == selection) { choose(option.value) }
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(index == highlighted ? Theme.surfaceHover : .clear))
                            .id(index)
                    }
                }
                .padding(6)
            }
            .frame(width: 240, height: min(CGFloat(max(options.count, 1)) * 33 + 12, 320))
            .focusable().focused($focused).focusEffectDisabled()
            .onAppear {
                highlighted = options.firstIndex { $0.value == selection }
                focused = true
                if let highlighted { reader.scrollTo(highlighted, anchor: .center) }
            }
            .onChange(of: highlighted) { _, index in
                if let index { withAnimation(.easeOut(duration: 0.1)) { reader.scrollTo(index) } }
            }
            .onKeyPress(.downArrow) { move(1); return .handled }
            .onKeyPress(.upArrow) { move(-1); return .handled }
            .onKeyPress(.return) {
                guard let highlighted, options.indices.contains(highlighted) else { return .ignored }
                choose(options[highlighted].value)
                return .handled
            }
            .onKeyPress(characters: .alphanumerics.union(.punctuationCharacters).union(.whitespaces)) { press in
                // A pause starts a new word, as a menu's type-select does.
                if Date().timeIntervalSince(typedAt) > 1 { typed = "" }
                typed += press.characters; typedAt = Date()
                if let match = options.firstIndex(where: { $0.label.lowercased().hasPrefix(typed.lowercased()) }) { highlighted = match }
                return .handled
            }
        }
    }

    private func move(_ step: Int) {
        guard !options.isEmpty else { return }
        highlighted = min(max((highlighted ?? (step > 0 ? -1 : options.count)) + step, 0), options.count - 1)
    }
}

/// A few exclusive choices side by side, as the Pull Requests tab's filter chips, in place of a
/// segmented control.
struct ThemedSegments<Value: Hashable>: View {
    let options: [ThemedOption<Value>]
    @Binding var selection: Value
    var id: String = ""

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                // Named by the value, not its words, so the name holds in every language.
                DashboardChip(title: option.label, count: nil, active: option.value == selection,
                              id: id.isEmpty ? "" : "\(id)-\(String(describing: option.value))") { selection = option.value }
            }
        }
        .fixedSize()
    }
}

/// One group of what an add list offers, under its header.
struct ThemedAddGroup: Hashable {
    struct Item: Hashable { let id: String; let title: String }
    let title: String
    let items: [Item]
}

/// A list of things to add, under a header per group, hung under `label` when it is clicked: the
/// floating list the composer uses, rather than a system menu. `checked` ticks the ones already in.
struct ThemedAddMenu<Label: View>: View {
    let groups: [ThemedAddGroup]
    var checked: Set<String> = []
    /// Whether choosing one leaves the list open, to choose another.
    var staysOpen = false
    let choose: (String) -> Void
    @ViewBuilder let label: () -> Label
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: { label() }
            .buttonStyle(.plain)
            .floatingPanel(isPresented: $open) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(groups.enumerated()), id: \.element) { index, group in
                            if index > 0 { Divider().padding(.vertical, 4) }
                            if !group.title.isEmpty {
                                Text(group.title).textCase(.uppercase)
                                    .font(.system(size: 10.5, weight: .semibold)).tracking(0.5)
                                    .foregroundStyle(Theme.textTertiary)
                                    .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 2)
                            }
                            ForEach(group.items, id: \.self) { item in
                                ChoiceRow(title: item.title, selected: checked.contains(item.id)) {
                                    choose(item.id)
                                    if !staysOpen { open = false }
                                }
                            }
                        }
                    }
                    .padding(6)
                }
                .frame(width: 280, height: min(CGFloat(groups.reduce(0) { $0 + $1.items.count + 1 }) * 33 + 12, 380))
            }
    }
}

/// On or Off beside an automation's switch, always as wide as the wider word, so switching it
/// moves nothing in the header around it.
struct AutomationModeLabel: View {
    let live: Bool

    var body: some View {
        ZStack(alignment: .trailing) {
            Text("On").hidden()
            Text("Off").hidden()
            Text(live ? String(localized: "On") : String(localized: "Off"))
                .foregroundStyle(live ? Theme.success : DashboardPalette.ink3)
        }
        .font(.system(size: 13, weight: .medium))
        .accessibilityHidden(true)
    }
}
