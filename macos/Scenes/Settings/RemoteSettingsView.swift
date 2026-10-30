import SwiftUI

/// Settings → Remote (`RemoteSettingsViewModel`). Two halves: this Mac as a host other Macs pair
/// with and read, then the Macs this one paired with, and the ones nearby it could.
struct RemoteSettingsView: View {
    @Bindable var model: RemoteSettingsViewModel
    /// The nearby Mac a code is being typed for, by id, or `manual` for an address typed.
    @State private var pairingWith: String?
    @State private var address = ""
    @State private var code = ""

    private static let manual = "manual"

    var body: some View {
        Group {
            Section {
                SettingsRow(title: String(localized: "Allow other Macs to connect"),
                            caption: String(localized: "Macs you pair with can see this Mac's sessions and read its chats. They cannot type into them.")) {
                    Toggle("Allow other Macs to connect", isOn: Binding(get: { model.enabled }, set: { value in Task { await model.setEnabled(value) } }))
                        .labelsHidden().toggleStyle(.switch).disabled(model.saving || model.status == nil)
                        .accessibilityIdentifier("settings-remote-enabled")
                }
                if model.enabled { pairingRow }
            } header: { Text("This Mac") }
            if !model.clients.isEmpty {
                Section("Macs that can see this Mac") {
                    ForEach(model.clients) { client in
                        SettingsRow(title: client.label, caption: lastSeen(client)) {
                            Button("Remove", role: .destructive) { Task { await model.revoke(client) } }
                        }
                    }
                }
            }
            Section {
                ForEach(model.peers) { peer in
                    SettingsRow(title: peer.name, caption: reach(peer)) {
                        Button("Forget", role: .destructive) { Task { await model.forget(peer) } }
                    }
                }
                ForEach(model.nearby, id: \.id) { sighting in
                    SettingsRow(title: sighting.name, caption: String(localized: "Nearby, not paired")) {
                        if pairingWith == sighting.id { codeField(address: sighting.address) } else {
                            Button("Pair…") { pairingWith = sighting.id; code = "" }.disabled(model.pairing)
                        }
                    }
                }
                SettingsRow(title: String(localized: "Pair by address"),
                            caption: String(localized: "For a Mac this one cannot find: its name or IP address and the port it shows.")) {
                    if pairingWith == Self.manual {
                        HStack {
                            TextField("mac-mini.local:52000", text: $address).frame(minWidth: 160)
                                .accessibilityIdentifier("settings-remote-address")
                            codeField(address: address)
                        }
                    } else {
                        Button("Pair…") { pairingWith = Self.manual; code = "" }.disabled(model.pairing)
                    }
                }
                if let error = model.pairError {
                    Text(error).foregroundStyle(Theme.danger).textSelection(.enabled)
                }
            } header: {
                Text("Macs this Mac shows")
            } footer: {
                Text("Their sessions show in the sidebar, each Mac in a section of its own. A Mac that is not answering is looked for while this page is open.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
            if let error = model.error {
                Section { Text(error).foregroundStyle(Theme.danger).textSelection(.enabled) }
            }
        }
    }

    @ViewBuilder private var pairingRow: some View {
        if let code = model.pairingCode, let closes = model.pairingCloses {
            SettingsRow(title: String(localized: "Pairing code"),
                        caption: [String(localized: "Type it on the other Mac, in Settings → Remote. Tries left: \(model.attemptsLeft)."),
                                  model.address.map { String(localized: "Address: \($0)") }].compactMap(\.self).joined(separator: "\n")) {
                HStack {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let left = max(0, Int(closes.timeIntervalSince(context.date)))
                        HStack {
                            Text(code.prefix(3) + " " + code.suffix(3))
                                .font(.system(.title2, design: .monospaced)).textSelection(.enabled)
                                .accessibilityIdentifier("settings-remote-code")
                            Text(String(format: "%d:%02d", left / 60, left % 60)).foregroundStyle(Theme.textSecondary).monospacedDigit()
                        }
                        .onChange(of: left == 0) { _, expired in if expired { model.pairingExpired() } }
                    }
                    Button("Done") { Task { await model.closePairing() } }
                }
            }
        } else {
            SettingsRow(title: String(localized: "Pair a Mac"),
                        caption: String(localized: "Shows a code for five minutes, to type on the other Mac.")) {
                Button("Show Code") { Task { await model.openPairing() } }
                    .accessibilityIdentifier("settings-remote-open-pairing")
            }
        }
    }

    private func codeField(address: String) -> some View {
        HStack {
            TextField("123456", text: $code).frame(width: 80).monospacedDigit()
                .accessibilityIdentifier("settings-remote-code-entry")
                .onSubmit { submit(address: address) }
            if model.pairing { ProgressView().controlSize(.small) } else {
                Button("Pair") { submit(address: address) }
                    .disabled(code.filter(\.isNumber).count != 6 || address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Button("Cancel") { pairingWith = nil }.disabled(model.pairing)
        }
    }

    private func submit(address: String) {
        Task {
            if await model.pair(address: address, code: code) { pairingWith = nil; code = ""; self.address = "" }
        }
    }

    private func reach(_ peer: RemotePeer) -> String {
        switch peer.reach {
        case .online: String(localized: "Connected")
        case .connecting: String(localized: "Connecting…")
        case .offline: String(localized: "Not answering")
        case .revoked: String(localized: "This Mac was removed there. Forget it and pair again.")
        case .changed: String(localized: "Its identity changed. Forget it and pair again.")
        }
    }

    private func lastSeen(_ client: RemoteClient) -> String {
        guard let seen = client.lastSeenAt.flatMap({ try? Date($0, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)) }) else {
            return String(localized: "Paired, not connected since")
        }
        return String(localized: "Last connected \(seen.formatted(.relative(presentation: .named)))")
    }
}
