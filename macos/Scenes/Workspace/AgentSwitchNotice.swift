import SwiftUI

/// The model the keyboard is choosing, at the foot of the terminal: the presets in Next Model's
/// order on one strip of glass, the chosen one picked out, as the system's own switchers show where
/// a step landed. Like ⌘Tab: each press of Next Model or of a preset's key moves the pick while its
/// modifiers are held, and letting them go takes the strip away and switches the agent to it. The
/// toolbar names no model, so this is where a switch is seen to happen.
struct AgentSwitchNoticeView: View {
    let model: SessionWorkspaceViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let notice = model.switchNotice {
                strip(notice.preset.selection)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.switchNotice)
        .padding(.bottom, 24)
        .allowsHitTesting(false)
        .background { AgentSwitchKeys(model: model, choosing: model.switchNotice != nil) }
    }

    /// The presets, or only the choice when it is none of them.
    private func strip(_ selection: AgentSelection) -> some View {
        let presets = model.agentPresets
        let chosen = presets.first { model.agentCatalog.selection($0.selection, isRunning: selection, among: presets) }
        let rows = chosen == nil ? [AgentPreset(id: "chosen", selection: selection)] : presets
        return HStack(spacing: 2) {
            ForEach(rows) { preset in
                let on = chosen == nil || preset.id == chosen?.id
                HStack(spacing: 6) {
                    Text(title(preset.selection)).fontWeight(on ? .semibold : .regular)
                        .foregroundStyle(on ? Theme.onProminent : Theme.textSecondary)
                    if let shortcut = preset.shortcut {
                        Text(shortcut.title).foregroundStyle(on ? Theme.onProminent.opacity(0.6) : Theme.textTertiary)
                    }
                }
                .padding(.horizontal, 12).frame(height: 30)
                // Black on a light window, white on a dark one: the pick, in no agent's colour.
                .background(on ? Theme.prominent : .clear, in: Capsule())
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: on)
            }
        }
        .font(.system(size: 13))
        .lineLimit(1)
        .padding(4)
        .noticeGlass()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Switching to \(title(selection))"))
    }

    private func title(_ selection: AgentSelection) -> String {
        let listed = model.agentCatalog.model(selection.model)
        let effort = listed?.efforts.first { $0.id == selection.effort }?.name
        return [listed?.name ?? selection.model, effort].compactMap { $0 }.joined(separator: " ")
    }
}

/// A command the agent could not be given, on the same glass at the foot of the session. It floats
/// rather than taking a row, which would resize the terminal and reflow the agent's screen, and it
/// goes by itself.
struct AgentCommandErrorView: View {
    let model: SessionWorkspaceViewModel
    static let shown: Duration = .seconds(5)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // Not over the switcher, which stands where it does.
            if let error = model.agentCommandError, model.switchNotice == nil {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(Theme.warn)
                    .lineLimit(2)
                    .padding(.horizontal, 14).frame(minHeight: 30)
                    .noticeGlass()
                    .accessibilityIdentifier("workspace-agent-error")
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                    .task(id: error) {
                        do { try await Task.sleep(for: Self.shown) } catch { return }
                        model.dismissAgentCommandError(error)
                    }
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.agentCommandError)
        .padding(.horizontal, 16).padding(.vertical, 24)
        .allowsHitTesting(false)
    }
}

/// The keys that end a choice: letting go of the shortcut's modifiers switches, Escape keeps the
/// model. A choice made with nothing held, from the menu bar, switches at once; leaving the app,
/// whose modifiers it then never sees let go, switches too.
private struct AgentSwitchKeys: NSViewRepresentable {
    let model: SessionWorkspaceViewModel
    /// Read in the parent's body, so a change to it updates this view.
    let choosing: Bool

    func makeNSView(context: Context) -> KeysView { KeysView() }
    func updateNSView(_ view: KeysView, context: Context) {
        view.model = model
        // Not while SwiftUI is updating the view: the choice it ends is what it is drawing.
        if choosing, !KeysView.modifiersHeld(NSEvent.modifierFlags) { DispatchQueue.main.async { model.commitPresetChoice() } }
    }

    final class KeysView: NSView {
        weak var model: SessionWorkspaceViewModel?
        private var monitor: Monitor?
        private var resign: Observer?

        static func modifiersHeld(_ flags: NSEvent.ModifierFlags) -> Bool {
            !flags.intersection([.command, .control, .option, .shift]).isEmpty
        }

        final class Monitor: @unchecked Sendable {
            let token: Any
            init(_ token: Any) { self.token = token }
            deinit { NSEvent.removeMonitor(token) }
        }
        final class Observer: @unchecked Sendable {
            let token: NSObjectProtocol
            init(_ token: NSObjectProtocol) { self.token = token }
            deinit { NotificationCenter.default.removeObserver(token) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            monitor = nil
            resign = nil
            guard window != nil else { return }
            let token = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
                guard let self, let model = self.model, model.switchNotice != nil else { return event }
                if event.type == .keyDown {
                    guard event.keyCode == 53, event.window === self.window else { return event }
                    model.cancelPresetChoice()
                    return nil
                }
                if !Self.modifiersHeld(event.modifierFlags) { model.commitPresetChoice() }
                return event
            }
            monitor = token.map(Monitor.init)
            resign = Observer(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.model?.commitPresetChoice() }
            })
        }
    }
}

private extension View {
    @ViewBuilder func noticeGlass() -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: Capsule())
        } else {
            background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.border, lineWidth: Theme.Size.hairline))
                .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        }
    }
}
