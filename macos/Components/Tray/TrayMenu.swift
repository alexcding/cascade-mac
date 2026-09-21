import AppKit
import SwiftUI

/// The menu bar tray: a native dropdown — the pull requests waiting on your review, plan
/// usage, Quit.
/// Either click on the status item opens it.
/// The menu is rebuilt each time it opens and whenever its data changes while it is up; every
/// row hands its click to the view model, which is the only thing that knows whether it may act.
@MainActor final class TrayMenuController: NSObject, NSMenuDelegate {
    /// Task Hub's row width: a longer title is cut and given an ellipsis.
    static let titleLimit = 38
    static let iconSide: CGFloat = 16
    static let usageWidth: CGFloat = 300

    let menu = NSMenu()
    private let model: TrayViewModel
    /// Told when the menu opens and closes; the owner decides what "active" means for the model.
    private let setActive: (Bool) -> Void
    private var isOpen = false
    nonisolated(unsafe) private var avatarObserver: NSObjectProtocol?
    /// The first row: whose plan the tray shows. Its width is the menu's.
    private lazy var agentItem: NSMenuItem = {
        let item = NSMenuItem()
        item.view = NSHostingView(rootView: TrayAgentRow(shell: model.shell))
        return item
    }()
    private lazy var usageItem: NSMenuItem = {
        let item = NSMenuItem()
        item.view = NSHostingView(rootView: TrayUsageRow(shell: model.shell, open: { [weak self] in
            self?.menu.cancelTracking(); self?.model.openUsage()
        }))
        return item
    }()

    init(model: TrayViewModel, setActive: @escaping (Bool) -> Void) {
        self.model = model; self.setActive = setActive
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        rebuild()
        observe()
        observeUsage()
        // A face that arrives after the menu opened swaps in for the octicon.
        avatarObserver = NotificationCenter.default.addObserver(forName: SidebarAvatars.loaded, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildIfOpen() }
        }
    }

    deinit { avatarObserver.map(NotificationCenter.default.removeObserver) }

    func menuWillOpen(_ menu: NSMenu) { isOpen = true; setActive(true); rebuild() }
    /// AppKit closes the menu and then delivers the chosen item's action, so the model stays
    /// active until that action has had its turn; deactivating here would drop the click.
    func menuDidClose(_ menu: NSMenu) {
        isOpen = false
        Task { @MainActor [weak self] in
            guard let self, !isOpen else { return }
            setActive(false)
        }
    }
    func dismiss() { menu.cancelTracking() }

    /// Two tracks: a review change rebuilds the rows; usage only changes what the two
    /// hosted SwiftUI rows draw, which they do on their own, so it is re-measured, not rebuilt —
    /// rebuilding would detach the very row that is handling the click.
    private func observe() {
        withObservationTracking {
            let shell = model.shell
            _ = model.snapshot(); _ = model.actionError; _ = model.active
            _ = shell.trayError
        } onChange: { [weak self] in
            Task { @MainActor in self?.rebuildIfOpen(); self?.observe() }
        }
    }
    private func observeUsage() {
        withObservationTracking {
            let shell = model.shell
            _ = shell.usageAgent; _ = shell.usage; _ = shell.usageLoading; _ = shell.usageError
        } onChange: { [weak self] in
            Task { @MainActor in self?.resizeIfOpen(); self?.observeUsage() }
        }
    }

    private func rebuildIfOpen() { if isOpen { rebuild() } }
    private func resizeIfOpen() { if isOpen { sizeRows() } }

    private func rebuild() {
        let shell = model.shell
        var items: [NSMenuItem] = [agentItem, .separator()]
        // The section exists only while there is something to review; nothing stands in for it.
        let snapshot = model.snapshot()
        let pending = snapshot.pending
        var listed = false
        if !pending.isEmpty { items.append(header("Review requested")); listed = true }
        if let error = shell.trayError {
            items.append(note(Self.truncate(pending.isEmpty ? "Reviews unavailable. \(error)" : "Showing last available reviews. \(error)", limit: 60)))
            listed = true
        }
        for pr in pending {
            let item = row("PR #\(pr.number) \(pr.title)", action: .openReview(pr.id), enabled: model.canOpen(pr, in: snapshot))
            item.image = TrayIcons.github(login: pr.author?.login, frozen: nil, ci: pr.ci)
            item.toolTip = "\(pr.projectName ?? pr.repo) · \(pr.ciLabel)"
            items.append(item)
        }
        // No placeholder: with nothing to review the menu goes straight from the picker to usage.
        if listed { items.append(.separator()) }
        sizeRows()
        items.append(usageItem)
        if let error = model.actionError { items.append(note(error)) }
        items.append(.separator())
        items.append(row("Quit Craft", action: .quit))
        menu.items = items
    }

    /// The hosted rows are SwiftUI views; a menu item takes a frame, not a layout, so each is
    /// measured here for the width it is given — on every build, so a text-size change lands.
    private func sizeRows() {
        for view in [agentItem.view, usageItem.view].compactMap({ $0 }) {
            view.layoutSubtreeIfNeeded()
            var size = view.fittingSize
            size.width = Self.usageWidth
            view.frame = NSRect(origin: .zero, size: size)
        }
    }

    private func row(_ title: String, action: TrayViewModel.Action, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: Self.truncate(title, limit: Self.titleLimit), action: #selector(rowClicked(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = TrayMenuAction(action)
        item.isEnabled = enabled
        return item
    }
    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)])
        return item
    }
    private func note(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func rowClicked(_ sender: NSMenuItem) {
        guard let boxed = sender.representedObject as? TrayMenuAction else { return }
        switch boxed.action {
        case .openUsage: model.openUsage()
        case .quit: model.quit()
        case .openReview(let id): model.openReview(id)
        case .refresh: break // Opening the menu is the refresh; no row asks for one.
        }
    }

    /// Task Hub's cut: the first `limit - 1` characters, trailing space dropped, then an ellipsis.
    static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = String(text.prefix(limit - 1))
        return head.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) + "…"
    }
}

/// An `Action` boxed for `representedObject`.
private final class TrayMenuAction: NSObject {
    let action: TrayViewModel.Action
    init(_ action: TrayViewModel.Action) { self.action = action }
}

/// Menu row icons: the PR author's round avatar with a CI dot at its corner, or the GitHub
/// mark when there is no face yet.
@MainActor enum TrayIcons {
    static func github(login: String?, frozen: String?, ci: TrayPR.CI?) -> NSImage? {
        let side = TrayMenuController.iconSide
        let dot: NSColor? = switch (ci?.status, ci?.conclusion) {
        case ("in_progress", _), ("queued", _): SidebarPalette.warn
        case (_, "success"): SidebarPalette.success
        case (_, "failure"): SidebarPalette.danger
        default: nil
        }
        guard let avatar = SidebarAvatars.image(login: login, frozen: frozen) else {
            return SidebarIcons.brand("github", size: side)
        }
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSBezierPath(ovalIn: rect).addClip()
            avatar.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            guard let dot else { return true }
            NSGraphicsContext.current?.cgContext.resetClip()
            let r: CGFloat = 5
            let dotRect = NSRect(x: rect.maxX - r, y: 0, width: r, height: r)
            // A clear ring, so the avatar is cut away around the dot whatever the menu is drawn on.
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dotRect.insetBy(dx: -1, dy: -1)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            dot.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            return true
        }
        return image
    }
}

/// Whose plan the tray shows, as the menu's first row. The same setting the Dashboard
/// toolbar's picker binds to, so the two never disagree. A custom control rather than the
/// system segmented one: a light, half-transparent track over the menu's own material, with
/// a soft pill under the chosen agent.
struct TrayAgentRow: View {
    let shell: ShellStore
    var body: some View {
        HStack(spacing: 2) {
            ForEach(Theme.usageAgents, id: \.key) { agent in
                let selected = shell.usageAgent == agent.key
                Button { shell.setUsageAgent(agent.key) } label: {
                    Text(agent.title)
                        .font(.system(size: 12, weight: selected ? .medium : .regular))
                        .foregroundStyle(selected ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background {
                            if selected {
                                Capsule().fill(Color.primary.opacity(0.12))
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("tray-agent-\(agent.key)")
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .padding(.horizontal, 14).padding(.vertical, 6)
        .frame(width: TrayMenuController.usageWidth)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tray-agent")
        .accessibilityLabel("Usage agent")
    }
}

/// The plan usage block as one menu row. A click goes to the Dashboard.
struct TrayUsageRow: View {
    let shell: ShellStore
    let open: () -> Void
    var body: some View {
        UsagePanel(shell: shell)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .frame(width: TrayMenuController.usageWidth, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            .accessibilityAddTraits(.isButton)
    }
}
