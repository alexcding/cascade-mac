import AppKit
import SwiftUI

/// The Simulator panel: the session's simulator, streamed natively (`SimulatorPaneModel`). The
/// device's screen when one is attached, else the devices to pick from, or what setup is missing.
struct SimulatorPanelView: View {
    let model: SimulatorPaneModel

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Under the pane's bar, not behind it: a background into the top safe area hides its tabs.
            .paneSurface(ignoresSafeAreaEdges: [])
            .overlay(alignment: .bottom) {
                if let message = model.actionError {
                    Text(message)
                        .font(.callout).foregroundStyle(Theme.danger)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Theme.dangerBackground, in: RoundedRectangle(cornerRadius: 8))
                        .padding(12)
                        .accessibilityIdentifier("simulator-action-error")
                }
            }
            .accessibilityIdentifier("workspace-simulator-panel")
            .onAppear { model.shown = true; model.load() }
            .onDisappear { model.shown = false }
            // Devices booted elsewhere meanwhile, or setup finished outside the app.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.load() }
            .confirmationDialog(bootLimitTitle, isPresented: Binding(get: { model.bootLimit != nil }, set: { if !$0 { model.dismissBootLimit() } }),
                                titleVisibility: .visible, presenting: model.bootLimit) { limit in
                ForEach(limit.candidates) { candidate in
                    Button(String(localized: "Shut Down \(candidate.name)")) { model.freeSlot(shuttingDown: candidate) }
                }
                Button(String(localized: "Cancel"), role: .cancel) { model.dismissBootLimit() }
            } message: { limit in
                Text(String(localized: "Cascade runs at most \(limit.limit) simulators it started. Shut one down to start \(limit.name)."))
            }
    }

    private var bootLimitTitle: String { String(localized: "Too many simulators running") }

    @ViewBuilder private var content: some View {
        if let blocker = model.blocker {
            SimulatorSetupView(blocker: blocker, checkAgain: model.load)
        } else if let device = model.device {
            SimulatorScreen(model: model, device: device)
        } else if model.state == nil {
            if let error = model.loadError {
                ContentUnavailableView {
                    Label(String(localized: "The simulators could not be listed"), systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: {
                    Button(String(localized: "Try Again"), action: model.load)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        } else {
            SimulatorDeviceList(model: model)
        }
    }
}

/// The attached device's screen, with what the attachment is waiting on over it.
private struct SimulatorScreen: View {
    let model: SimulatorPaneModel
    let device: DeviceDescriptor

    var body: some View {
        VStack(spacing: 0) {
            if let notice = model.availability.degradedNotice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(Theme.warn)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Theme.warnBackground)
            }
            ZStack {
                DeviceScreenSurface(view: model.screen)
                    .padding(12)
                if let error = model.error, model.state?.attachPhase == nil {
                    ContentUnavailableView {
                        Label(String(localized: "\(device.name) is not showing"), systemImage: "exclamationmark.triangle")
                    } description: { Text(error) } actions: {
                        Button(String(localized: "Try Again"), action: model.retry)
                    }
                } else if let status = model.attachStatus ?? (model.rendering || device.state != .booted ? nil : String(localized: "Connecting…")) {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(status).foregroundStyle(Theme.textTertiary)
                        Text(device.name).font(.callout).foregroundStyle(Theme.textSecondary)
                    }
                    .accessibilityIdentifier("simulator-attach-status")
                } else if device.state == .shutdown {
                    ContentUnavailableView {
                        Label(String(localized: "\(device.name) is shut down"), systemImage: "iphone.slash")
                    } actions: {
                        Button(String(localized: "Boot"), action: { model.select(device) })
                    }
                }
            }
        }
    }
}

/// Hosts the model's screen view: the view is the model's, this only puts it on screen.
private struct DeviceScreenSurface: NSViewRepresentable {
    let view: DeviceScreenView
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ host: NSView, context: Context) {
        guard view.superview !== host else { return }
        view.removeFromSuperview()
        view.frame = host.bounds
        view.autoresizingMask = [.width, .height]
        host.addSubview(view)
    }
}

/// No device attached: the simulators to pick from, the running ones first.
private struct SimulatorDeviceList: View {
    let model: SimulatorPaneModel

    var body: some View {
        if model.devices.isEmpty {
            ContentUnavailableView {
                Label(String(localized: "No simulators"), systemImage: "iphone.slash")
            } description: {
                Text(String(localized: "Add a simulator in Xcode’s Devices and Simulators window, then come back."))
            } actions: {
                Button(String(localized: "Check Again"), action: model.load)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "Choose a simulator"))
                        .font(.headline).padding(.bottom, 6)
                    ForEach(model.devices) { device in
                        SimulatorDeviceRow(device: device, busy: model.busy) { model.select(device) }
                    }
                }
                .padding(16)
                .readableColumn(420)
            }
            .accessibilityIdentifier("simulator-device-list")
        }
    }
}

private struct SimulatorDeviceRow: View {
    let device: DeviceDescriptor
    let busy: Bool
    let open: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.family == "tablet" ? "ipad" : "iphone")
                .foregroundStyle(device.state == .booted ? Theme.accent : Theme.textTertiary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).lineLimit(1)
                Text("\(device.runtime) · \(device.state.label)").font(.caption).foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 8)
            switch device.state {
            case .booted: Button(String(localized: "Open"), action: open).disabled(busy)
            case .shutdown: Button(String(localized: "Boot"), action: open).disabled(busy)
            case .booting, .shuttingDown: ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Theme.surfaceHover.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("simulator-device-\(device.udid)")
    }
}

/// What the Simulator needs that this Mac does not have yet, step by step.
private struct SimulatorSetupView: View {
    let blocker: DeviceAvailability.Blocker
    let checkAgain: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(blocker.title).font(.headline)
            Text(blocker.detail).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            if !blocker.steps.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(blocker.steps) { step in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: step.done ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(step.done ? Theme.success : Theme.textTertiary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(step.label).foregroundStyle(step.done ? Theme.textSecondary : .primary)
                                if let detail = step.detail, !step.done {
                                    Text(detail).font(.caption.monospaced()).foregroundStyle(Theme.textTertiary).textSelection(.enabled)
                                }
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .accessibilityIdentifier("simulator-setup-steps")
            }
            HStack {
                // The one step there is somewhere to send the user for.
                if blocker.steps.first(where: { !$0.done })?.id == "install-xcode",
                   let store = URL(string: "https://apps.apple.com/app/xcode/id497799835") {
                    Button(String(localized: "Open Mac App Store")) { openURL(store) }
                }
                if blocker.retryable { Button(String(localized: "Check Again"), action: checkAgain) }
            }
        }
        .padding(20)
        .readableColumn(460)
        .frame(maxHeight: .infinity)
    }
}

/// The pane's row over the Simulator: which device, what it is doing, and its hardware buttons.
struct SimulatorBar: View {
    let model: SimulatorPaneModel

    var body: some View {
        HStack(spacing: 8) {
            devicePicker
            if model.agentActive {
                Label(String(localized: "Agent"), systemImage: "sparkles")
                    .font(.caption.weight(.medium)).foregroundStyle(Theme.accent)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Theme.accentBackground, in: Capsule())
                    .help(String(localized: "An agent is driving this simulator"))
                    .accessibilityIdentifier("simulator-agent-badge")
            }
            if let status = model.attachStatus {
                ProgressView().controlSize(.mini)
                Text(status).font(.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
            } else if model.busy {
                ProgressView().controlSize(.mini)
            }
            Spacer(minLength: 4)
            if model.device?.state == .booted {
                hardware(.home, "circle", String(localized: "Home (⇧⌘H)"))
                hardware(.lock, "lock", String(localized: "Lock (⌘L)"))
                hardware(.volumeDown, "speaker.minus", String(localized: "Volume Down (⌘↓)"))
                hardware(.volumeUp, "speaker.plus", String(localized: "Volume Up (⌘↑)"))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .accessibilityIdentifier("workspace-simulator-bar")
    }

    private func hardware(_ button: DeviceKeyboard.Button, _ symbol: String, _ help: String) -> some View {
        Button { model.press(button) } label: { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .help(help)
            .accessibilityLabel(help)
    }

    private var devicePicker: some View {
        Menu {
            let devices = model.devices
            let running = devices.filter { $0.state == .booted }
            let others = devices.filter { $0.state != .booted }
            if !running.isEmpty {
                Section(String(localized: "Running")) {
                    ForEach(running) { device in
                        Toggle(isOn: Binding(get: { model.state?.attachedDeviceUdid == device.udid },
                                             set: { if $0 { model.select(device) } })) {
                            Text("\(device.name) — \(device.runtime)")
                        }
                    }
                }
            }
            if !others.isEmpty {
                Section(String(localized: "Shut Down")) {
                    ForEach(others) { device in
                        Button(String(localized: "Boot \(device.name) — \(device.runtime)")) { model.select(device) }
                            .disabled(device.state != .shutdown)
                    }
                }
            }
            if let device = model.device {
                Divider()
                Button(String(localized: "Detach \(device.name)"), action: model.detach)
                if device.state == .booted {
                    Button(String(localized: "Shut Down \(device.name)"), action: model.shutDown)
                }
            }
            Divider()
            Button(String(localized: "Refresh List"), action: model.load)
        } label: {
            Label(model.device?.name ?? String(localized: "Choose a Simulator"),
                  systemImage: model.device?.family == "tablet" ? "ipad" : "iphone")
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.blocker != nil)
        .accessibilityIdentifier("simulator-device-picker")
    }
}
