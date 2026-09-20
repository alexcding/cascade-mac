import SwiftUI

/// Safari's compact tab layout, shared by every panel that has tabs: all tabs sit inside one pill,
/// and the selected tab is a raised glass capsule that doubles as the panel's field (an address for
/// the browser, a file search for Files). A panel supplies its own leading control, tab icon,
/// trailing accessories and suggestion rows; the chrome, metrics and focus handling live here.
enum CompactTabMetrics {
    /// A tab is never wider than this; below it, tabs split the available width equally.
    static let maxTabWidth: CGFloat = 400
    /// A web tab's cap, a fifth narrower: an address needs less room than a file's name and search.
    static let maxWebTabWidth: CGFloat = 320
    /// Safari's compact bar: a 36pt field inside a 40pt pill, 15pt text.
    static let pillHeight: CGFloat = 40
    static let tabHeight: CGFloat = 36
    static let barHeight: CGFloat = 56
    static let tabFont = Font.system(size: 15)
    /// The same size as the text. AppKit draws a field's prompt in the field's own font whatever
    /// the prompt asks for, so a smaller placeholder on the resting label sat on a different line
    /// box from the focused field and the text jumped off-centre between the two states.
    static let placeholderFont = tabFont
    /// The least a tab can be and still show its title, and the least the selected tab can be and
    /// still be typed into. An icon-only tab is exactly its icon slot.
    static let minTitledTabWidth: CGFloat = 120
    static let minActiveTabWidth: CGFloat = 180
    static let iconTabWidth: CGFloat = 36
    static let tabSpacing: CGFloat = 2
    /// A titled tab's side padding, and the leading slot inside it that holds Close.
    static let tabPadding: CGFloat = 6
    static let closeSlotWidth: CGFloat = 24
    static let pillInset: CGFloat = 2
}

/// How the tabs fit the width the pill is given, as Safari degrades: titled tabs sharing the row
/// while they fit; then every unselected tab as its icon alone; then, when even the icons overrun,
/// the leftmost tabs left out until the rest fit. The selected tab is never left out.
struct CompactTabLayout<ID: Hashable>: Equatable {
    let visible: [ID]
    let iconOnly: Bool

    init(ids: [ID], activeID: ID?, available: CGFloat) {
        func width(_ count: Int, inactive: CGFloat) -> CGFloat {
            guard count > 0 else { return 0 }
            return CompactTabMetrics.minActiveTabWidth + CGFloat(count - 1) * (inactive + CompactTabMetrics.tabSpacing)
                + 2 * CompactTabMetrics.pillInset
        }
        // Unmeasured yet: lay out as if there were room, rather than flashing the icon-only state.
        guard available > 0, width(ids.count, inactive: CompactTabMetrics.minTitledTabWidth) > available else {
            visible = ids; iconOnly = false; return
        }
        var kept = ids
        while kept.count > 1, width(kept.count, inactive: CompactTabMetrics.iconTabWidth) > available,
              let index = kept.firstIndex(where: { $0 != activeID }) {
            kept.remove(at: index)
        }
        visible = kept; iconOnly = true
    }
}

/// The bar's row: a leading control, the centred pill, and New Tab trailing it. The suggestion
/// list hangs under the row, above whatever the panel shows beneath.
struct CompactTabBar<Leading: View, Pill: View, Suggestions: View>: View {
    let newTabTitle: String
    let newTabHelp: String
    let newTab: () -> Void
    @ViewBuilder let leading: Leading
    /// Given the width left between the leading control and New Tab.
    @ViewBuilder let pill: (CGFloat) -> Pill
    @ViewBuilder let suggestions: Suggestions

    var body: some View {
        HStack(spacing: 8) {
            leading
            // The pill is centred in whatever the row has left, and told how much that is: tabs that
            // would overrun it fall back to icons rather than pushing New Tab out of the pane.
            GeometryReader { proxy in
                pill(proxy.size.width).frame(width: proxy.size.width, height: proxy.size.height)
            }
            // The 32pt square is the label, not a frame around the button, so the whole capsule
            // takes the click rather than the 14pt glyph alone.
            Button(action: newTab) {
                Label(newTabTitle, systemImage: "plus")
                    .labelStyle(SquareIconLabelStyle())
                    .frame(width: Theme.Size.largeControl, height: Theme.Size.largeControl)
                    .contentShape(Rectangle())
            }
            .help(newTabHelp)
            .barGlass()
        }
        .padding(.horizontal, 12)
        .frame(height: CompactTabMetrics.barHeight)
        // Above the content beneath, or the list would render under it.
        .zIndex(1)
        .overlay(alignment: .top) { suggestions.padding(.top, 52) }
    }
}

/// The outer pill hugs its tabs, each an equal share of the row up to `maxTabWidth`. The raised
/// capsule belongs to the selected tab and moves with it.
struct CompactTabPill<ID: Hashable, Tab: View>: View {
    let allIDs: [ID]
    let activeID: ID?
    let available: CGFloat
    /// Dragging a tab along the pill moves it before the given tab, or to the end for nil.
    let move: (ID, ID?) -> Void
    /// Whether a tab has a place in the order at all. One that does not is not given the drag.
    let canMove: (ID) -> Bool
    let select: (ID) -> Void
    /// The widest a titled tab grows, and so the widest a lone tab's pill is.
    let maxTabWidth: CGFloat
    /// The tab for an id, and whether it is to draw as its icon alone.
    @ViewBuilder let tab: (ID, Bool) -> Tab
    /// Where each tab is laid out in the pill, which is what a drag is measured against.
    @State private var frames: [ID: CGRect] = [:]
    @State private var drag: TabDrag?
    private let pillSpace = "compact-tab-pill"

    /// The unselected tab a gesture has asked to select, so that it asks once and not per event.
    @State private var picked: ID?

    /// A drag in progress: the tab, where the pointer was when it took hold, how far the tab's slot
    /// has moved along the row since, and where the pointer is.
    private struct TabDrag { let id: ID; let origin: CGFloat; var shift: CGFloat; var pointer: CGFloat }

    init(ids: [ID], activeID: ID?, available: CGFloat, maxTabWidth: CGFloat = CompactTabMetrics.maxTabWidth,
         select: @escaping (ID) -> Void, move: @escaping (ID, ID?) -> Void,
         canMove: @escaping (ID) -> Bool = { _ in true }, @ViewBuilder tab: @escaping (ID, Bool) -> Tab) {
        allIDs = ids; self.activeID = activeID; self.available = available; self.maxTabWidth = maxTabWidth
        self.select = select; self.move = move; self.canMove = canMove; self.tab = tab
    }

    var body: some View {
        let layout = CompactTabLayout(ids: allIDs, activeID: activeID, available: available)
        let ids = layout.visible
        if ids.isEmpty {
            // Momentarily empty while the blank tab is created; holds the row's shape.
            Capsule().fill(Theme.surfaceHover)
                .overlay(Capsule().strokeBorder(Theme.border, lineWidth: Theme.Size.hairline))
                .frame(maxWidth: maxTabWidth).frame(height: CompactTabMetrics.pillHeight)
        } else {
            HStack(spacing: CompactTabMetrics.tabSpacing) {
                ForEach(ids, id: \.self) { id in
                    let iconOnly = layout.iconOnly && id != activeID
                    tab(id, iconOnly)
                        .frame(maxWidth: iconOnly ? CompactTabMetrics.iconTabWidth : maxTabWidth)
                        // Behind its own tab, inside the transition, so a tab that slides in or out
                        // carries its capsule with it. One capsule gliding between slots arrives
                        // after the tab does, and the field's text shows outside it on the way.
                        .background { if id == activeID { ActiveTabCapsule() } }
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(pillSpace)) } action: { frames[id] = $0 }
                        // The dragged tab stays under the pointer: its slot changes as it passes its
                        // neighbours, and the offset makes up the difference. It takes each new slot
                        // at once, so that only the tabs making way are seen to slide.
                        .offset(x: drag.flatMap { $0.id == id ? $0.pointer - $0.origin - $0.shift : nil } ?? 0)
                        .zIndex(drag?.id == id ? 1 : 0)
                        .transaction { if drag?.id == id { $0.animation = nil } }
                        .simultaneousGesture(reorder(id, titled: !iconOnly, among: ids), including: canMove(id) ? .all : .subviews)
                }
            }
            .coordinateSpace(.named(pillSpace))
            .onChange(of: ids) { _, ids in frames = frames.filter { ids.contains($0.key) } }
            .padding(2)
            .frame(height: CompactTabMetrics.pillHeight)
            .background(Theme.surfaceHover, in: Capsule())
            // A tab sliding in starts a full width to the right: keep it inside the pill.
            .clipShape(PillSlideClip())
            .overlay(Capsule().strokeBorder(Theme.border, lineWidth: Theme.Size.hairline))
        }
    }
}

extension CompactTabPill {
    /// Safari's tab drag. The tab follows the pointer along the pill and takes the place of each
    /// neighbour whose middle the pointer crosses. It needs a few points of travel to begin, so a
    /// click still selects.
    private func reorder(_ id: ID, titled: Bool, among ids: [ID]) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named(pillSpace))
            .onChanged { value in
                // A press that began on Close is a click on Close, however far it wanders: it must
                // not turn into a drag that selects the tab it was meant to close.
                // Asked only before the drag takes hold: once the tab moves, so does its frame.
                if drag == nil, titled, let frame = frames[id],
                   value.startLocation.x - frame.minX < CompactTabMetrics.tabPadding + CompactTabMetrics.closeSlotWidth { return }
                // A dragged tab is the selected tab, as in Safari. Selecting can change widths, so
                // the drag takes hold only once this tab is the selected one, and asks just once.
                guard id == activeID else {
                    if picked != id { picked = id; select(id) }
                    return
                }
                if drag == nil { drag = TabDrag(id: id, origin: value.location.x, shift: 0, pointer: value.location.x) }
                guard drag?.id == id, let from = ids.firstIndex(of: id) else { return }
                drag?.pointer = value.location.x
                let others = ids.filter { $0 != id }
                let to = others.filter { (frames[$0]?.midX ?? .infinity) < value.location.x }.count
                guard to != from else { return }
                // The slot moves by exactly the tabs it passes. Worked out here rather than measured:
                // a measurement lands a frame after the swap, and the tab shook for that frame. A
                // neighbour not measured yet would throw the sum off for the rest of the drag, so
                // the swap waits for it.
                let widths = (to > from ? ids[(from + 1)...to] : ids[to..<from]).map { frames[$0]?.width }
                guard !widths.contains(nil) else { return }
                let distance = widths.reduce(0) { $0 + ($1 ?? 0) + CompactTabMetrics.tabSpacing }
                drag?.shift += to > from ? distance : -distance
                move(id, to < others.count ? others[to] : nil)
            }
            .onEnded { _ in
                picked = nil
                withAnimation(.snappy(duration: 0.2)) { drag = nil }
            }
    }
}

/// One tab in the pill. Unselected: icon and title, a close button on hover. Selected: close,
/// icon and label, the panel's accessories, and the field over the label while editing. Both
/// states share the same slots, so the label never moves; only what fills the slots crossfades.
struct CompactTabShell<Icon: View, Accessories: View>: View {
    /// Empty shows `placeholder` in its place.
    let label: String
    let placeholder: String
    let closeTitle: String
    let help: String
    let active: Bool
    /// Hidden workspaces stay mounted; opacity does not stop a field from taking first responder.
    let workspaceActive: Bool
    /// A blank tab takes the keyboard when it becomes active, unless the bar opened it itself.
    let blank: Bool
    let autoFocus: Bool
    let closable: Bool
    /// The row has no room for titles: an unselected tab draws as its icon, and Close takes the
    /// icon's place under the pointer.
    var iconOnly = false
    /// False for a tab whose title is fixed once opened: selecting it never turns it into a field.
    var editable = true
    @Binding var text: String
    @FocusState.Binding var editing: Bool
    let moveHighlight: (Int) -> Bool
    /// Enter: true when the text was accepted and the field should be released.
    let submit: () -> Bool
    let select: () -> Void
    let close: () -> Void
    @ViewBuilder let icon: Icon
    /// Trailing buttons, given whether the pointer is over the tab.
    @ViewBuilder let accessories: (Bool) -> Accessories
    @State private var hovering = false
    @State private var hoveringClose = false

    private var isEditing: Bool { active && editing }
    /// The selected tab shows Close; a titled tab also shows it under the pointer, since the title
    /// beside it is still there to select with. A tab shrunk to its icon never does: Close would
    /// cover the only place to click. While the field is edited the slot holds the magnifying glass,
    /// and Close comes back under the pointer.
    private var showsClose: Bool { closable && (isEditing ? hoveringClose : active || hovering) }

    var body: some View {
        if iconOnly && !active { iconTab } else { titledTab }
    }

    private var iconTab: some View {
        Button(action: select) {
            icon.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label.isEmpty ? placeholder : label)
        .accessibilityHint("Select tab")
        .frame(width: CompactTabMetrics.iconTabWidth, height: CompactTabMetrics.tabHeight)
        .background(hovering ? Theme.border.opacity(0.5) : .clear, in: Capsule())
        .onHover { hovering = $0 }
        .help(label.isEmpty ? help : label)
        .accessibilityAction(named: closeTitle, close)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var titledTab: some View {
        HStack(spacing: 4) {
            // Safari's leading slot: one 24pt position that holds Close at rest and the magnifying
            // glass while the field is edited, so neither ever pushes the text sideways.
            ZStack {
                Button(closeTitle, systemImage: "xmark.circle.fill", action: close)
                    .labelStyle(.iconOnly).buttonStyle(.plain)
                    .font(.system(size: 17))
                    .foregroundStyle(hoveringClose ? Theme.textSecondary : Theme.textTertiary)
                    .help("Close tab")
                    .opacity(showsClose ? 1 : 0)
                    .allowsHitTesting(showsClose)
                    .accessibilityHidden(!showsClose)
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textTertiary)
                    .opacity(isEditing && !showsClose ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .frame(width: CompactTabMetrics.closeSlotWidth, height: CompactTabMetrics.closeSlotWidth)
            // On the slot, not the button: a hidden button does not hit-test, so it never hovers.
            .contentShape(Rectangle())
            .onHover { hoveringClose = $0 }
            ZStack {
                Button(action: { if !active { select() } else if editable { editing = true } }) {
                    HStack(spacing: 6) {
                        icon
                        Text(label.isEmpty ? placeholder : label)
                            .font(label.isEmpty ? CompactTabMetrics.placeholderFont : CompactTabMetrics.tabFont)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(label.isEmpty ? Theme.textTertiary : active ? .primary : Theme.textSecondary)
                            .contentTransition(.interpolate)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(help)
                .accessibilityLabel(label.isEmpty ? placeholder : label)
                .accessibilityHint(!active ? "Select tab" : editable ? "Edit" : "")
                .opacity(isEditing ? 0 : 1)
                .allowsHitTesting(!isEditing)
                if active && editable {
                    // Mounted for the whole time the tab is selected, never inserted on demand: a
                    // focus binding set before its field exists is silently reset. Nothing here may
                    // depend on the typed text; a modifier flipping on the first character rebuilds
                    // the field and drops first responder mid-word.
                    TextField("", text: $text, prompt: Text(placeholder).font(CompactTabMetrics.placeholderFont))
                        .textFieldStyle(.plain)
                        .font(CompactTabMetrics.tabFont)
                        .multilineTextAlignment(.leading)
                        .focused($editing)
                        .onKeyPress(.downArrow) { moveHighlight(1) ? .handled : .ignored }
                        .onKeyPress(.upArrow) { moveHighlight(-1) ? .handled : .ignored }
                        .onSubmit { if submit() { editing = false } }
                        .onExitCommand { editing = false }
                        .opacity(isEditing ? 1 : 0)
                        .allowsHitTesting(isEditing)
                        .accessibilityHidden(!isEditing)
                }
            }
            accessories(hovering)
        }
        .padding(.horizontal, CompactTabMetrics.tabPadding)
        .frame(height: CompactTabMetrics.tabHeight)
        .background(hovering && !active ? Theme.border.opacity(0.5) : .clear, in: Capsule())
        // Safari's focus ring while the field is being edited.
        .overlay { if isEditing { Capsule().strokeBorder(Theme.accent.opacity(0.6), lineWidth: 3).padding(-1) } }
        .onHover { hovering = $0 }
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityAction(named: closeTitle, close)
        .animation(.easeInOut(duration: 0.15), value: active)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onAppear { takeFocusIfBlank() }
        .onChange(of: active) { _, _ in takeFocusIfBlank() }
        .onChange(of: workspaceActive) { _, _ in takeFocusIfBlank() }
    }

    /// Deferred one turn: the field is inserted in the same update that makes the tab active, and
    /// a focus binding set before the focus system has registered its field is silently dropped.
    private func takeFocusIfBlank() {
        guard autoFocus, active, workspaceActive, blank else { return }
        Task { @MainActor in
            if active, workspaceActive, blank { editing = true }
        }
    }
}

/// A trailing button inside the selected tab: 24pt, icon only, faded out rather than removed so
/// the label beside it never shifts.
struct CompactTabAccessory: View {
    let title: String
    let systemImage: String
    var size: CGFloat = 15
    var tint: Color = Theme.textSecondary
    let visible: Bool
    /// Hover is a pointer affordance: a button hidden only by hover stays reachable to VoiceOver.
    var accessible: Bool? = nil
    let action: () -> Void

    var body: some View {
        Button(title, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly).buttonStyle(.plain)
            .font(.system(size: size))
            .foregroundStyle(tint)
            .frame(width: 24, height: 24)
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .accessibilityHidden(!(accessible ?? visible))
    }
}

/// One control in the bar's leading cluster: a 32pt circle that tints on hover, as Safari's do.
struct HoverCircleButton: View {
    let title: String
    let systemImage: String
    let enabled: Bool
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, systemImage: String, enabled: Bool, action: @escaping () -> Void) {
        self.title = title; self.systemImage = systemImage; self.enabled = enabled; self.action = action
    }

    var body: some View {
        // The circle is the button's label, so the whole 32pt disc takes the click, not just the
        // glyph inside it.
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(enabled ? Theme.textSecondary : Theme.textTertiary.opacity(0.6))
                .frame(width: Theme.Size.largeControl, height: Theme.Size.largeControl)
                .background(hovering && enabled ? Theme.border.opacity(0.6) : .clear, in: Circle())
                .contentShape(Circle())
        }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// The completion list under the field. Headings are not rows: `highlighted` indexes `items` only.
struct CompactSuggestionList<Item: Identifiable, Icon: View>: View {
    let items: [Item]
    let highlighted: Int?
    let accessibilityLabel: String
    /// The section a row sits under; nil for none.
    let heading: (Item) -> String?
    let title: (Item) -> String
    /// A second line; empty for a single-line row.
    let detail: (Item) -> String
    let pick: (Item) -> Void
    @ViewBuilder let icon: (Item) -> Icon
    static var iconSide: CGFloat { 28 }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if let heading = heading(item), index == 0 || self.heading(items[index - 1]) != heading {
                    Text(heading).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 10).padding(.top, index == 0 ? 4 : 8).padding(.bottom, 2)
                }
                Button { pick(item) } label: {
                    HStack(spacing: 10) {
                        icon(item).frame(width: Self.iconSide, height: Self.iconSide)
                        if detail(item).isEmpty {
                            Text(title(item)).lineLimit(1)
                        } else {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(title(item)).lineLimit(1)
                                Text(detail(item)).font(.system(size: 12)).lineLimit(1).truncationMode(.head).foregroundStyle(Theme.textTertiary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .font(CompactTabMetrics.tabFont)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .background(highlighted == index ? Theme.accentBackground : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .frame(width: 560)
        .suggestionGlass()
        .accessibilityLabel(accessibilityLabel)
    }
}

/// A symbol standing in for a favicon in a suggestion row: a search, or a file.
struct CompactSuggestionSymbol: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.textSecondary)
            .frame(width: 28, height: 28)
            .background(Theme.surfaceHover, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// Down/Up over a suggestion list of `count` rows: positions nil (none) through count-1, wrapping.
func compactHighlight(_ highlighted: Int?, moving delta: Int, count: Int) -> Int? {
    // Shift to 0-based, step, wrap, shift back.
    let next = ((highlighted ?? -1) + 1 + delta + count + 1) % (count + 1) - 1
    return next == -1 ? nil : next
}

/// The suggestion list's panel: Liquid Glass on macOS 26, the window surface with a hairline before it.
private extension View {
    @ViewBuilder func suggestionGlass() -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(Color(nsColor: .windowBackgroundColor), in: shape)
                .overlay(shape.strokeBorder(Theme.border, lineWidth: Theme.Size.hairline))
                .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        }
    }
}

/// The bar's chrome buttons share one look: 32pt tall, icon-only at 20pt, plain buttons over a
/// Liquid Glass capsule on macOS 26 and a tinted bordered capsule before it.
extension View {
    @ViewBuilder func barGlass(iconOnly: Bool = true) -> some View {
        let base = labelStyle(iconOnly ? AnyLabelStyle(SquareIconLabelStyle()) : AnyLabelStyle(.titleAndIcon))
            .buttonStyle(.plain)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
            .frame(height: Theme.Size.largeControl)
        if #available(macOS 26.0, *) {
            base.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            base.background(Theme.surfaceHover, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.border, lineWidth: Theme.Size.hairline))
        }
    }
}

/// The pill's clip for tabs sliding in and out. Tabs only ever travel sideways, so the pill's round
/// ends are what has to cut them. Between the ends it is open above and below, for what the
/// selected tab draws past its own edge: the capsule's shadow and the focus ring.
private struct PillSlideClip: Shape {
    func path(in rect: CGRect) -> Path {
        let slack = (CompactTabMetrics.barHeight - CompactTabMetrics.pillHeight) / 2
        return Capsule().path(in: rect).union(Path(rect.insetBy(dx: rect.height / 2, dy: -slack)))
    }
}

/// The raised background of the selected tab: Liquid Glass on macOS 26, a lifted capsule before.
private struct ActiveTabCapsule: View {
    var body: some View {
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            Capsule().fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
        }
    }
}

/// Type-erased label style, so one modifier can pick between two.
private struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init<S: LabelStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
