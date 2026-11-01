import AppKit
import Foundation

/// Other Macs: the sidebar's section per paired Mac, its chats shown read-only, and the events its
/// backend relays (`docs/remote/05-mac-to-mac.md`).
extension AppViewModel {
    func connectRemote(_ service: (any RemoteServing)?) {
        // Each terminal reaches its Mac through the service it was made with: a new one, or none,
        // makes them anew.
        for model in remoteTerminals.values { model.retire() }
        remoteTerminals = [:]
        remotePeers.onRead = { [weak self] in self?.remoteRead() }
        remotePeers.connect(service)
        settings?.remote.onStatus = { [weak self] in self?.advertiseHost($0) }
        settings?.remote.connect(service)
        advertiseHost(nil)
        guard let service else { return }
        let daemon = platformFactory.terminalDaemonSocket()
        Task { [weak self] in
            // Before anything else: a paired Mac may open a session's terminal as soon as it can.
            if let daemon { try? await service.setTerminalDaemon(socket: daemon) }
            guard let status = try? await service.status(), let self, remotePeers.service != nil else { return }
            advertiseHost(status)
        }
    }

    /// This Mac is on Bonjour for as long as other Macs may connect: a Mac paired with it finds it
    /// again there when its address or port changed, and a new one lists it to pair with.
    func advertiseHost(_ status: RemoteStatus?) {
        guard let status, status.enabled, let port = status.port, let fingerprint = status.fingerprint else {
            hostAdvertiser?.advertiser.stop(); hostAdvertiser = nil
            return
        }
        let name = RemoteBonjour.computerName() ?? "Mac"
        let key = "\(name) \(port) \(fingerprint)"
        guard hostAdvertiser?.key != key else { return }
        hostAdvertiser?.advertiser.stop()
        hostAdvertiser = RemoteAdvertiser(name: name, port: port, fingerprint: fingerprint).map { (key, $0) }
    }

    /// Each paired Mac's section, in the order they were paired.
    func remoteSections() -> [SidebarRemoteSection] {
        remotePeers.peers.map { peer in
            SidebarRemoteSection(peer: peer, sessions: remotePeers.sessions[peer.id] ?? [],
                                 projects: remotePeers.projects[peer.id] ?? [],
                                 chats: remotePeers.visibleChats(peer.id))
        }
    }

    func remoteTitles() -> [SidebarDestination: String] {
        var titles: [SidebarDestination: String] = [:]
        for (peer, chats) in remotePeers.chats {
            for (id, chat) in chats { titles[.remoteChat(peer: peer, thread: id)] = chat.label }
        }
        for (peer, sessions) in remotePeers.sessions {
            for session in sessions { titles[.remoteSession(peer: peer, session: session.id)] = session.label }
        }
        return titles
    }

    private func remoteTerminalKey(peer: String, session: String) -> String { "\(peer)/\(session)" }

    /// The screen for a paired Mac's session: its terminal there, attached through this Mac's
    /// backend (`RemoteServing.openTerminal`). Made the first time it is shown, and kept.
    func remoteTerminal(peer: String, session id: String) -> RemoteTerminalModel? {
        guard let service = remotePeers.service, let mac = remotePeers.peer(peer),
              let session = remotePeers.sessions[peer]?.first(where: { $0.id == id }) else { return nil }
        let key = remoteTerminalKey(peer: peer, session: id)
        // Kept even once over: the screen is rebuilt on every read of the Mac, and attaching afresh
        // each time would open a connection there on every read. Reconnect attaches again.
        if let model = remoteTerminals[key] {
            model.update(session: session, macName: mac.name)
            return model
        }
        // Keyed and paired as the other Mac's app made it, so its daemon's list finds it.
        let terminal = platformFactory.terminal(.init(key: session.id, directory: session.worktree, paired: true))
        terminal.remote = RemoteTerminalSource(name: mac.name, socket: { try await service.openTerminal(peer: peer) })
        terminal.presentation.style = shell.terminalStyle
        // Only a web link is followed: a file it names is on the other Mac.
        terminal.openLink = { [weak self] raw, _, _ in
            guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased()) else { return }
            self?.desktop.openBrowser(url)
        }
        let model = RemoteTerminalModel(peer: peer, session: session, macName: mac.name, terminal: terminal)
        model.onReconnect = { [weak self] in
            guard let self else { return }
            if remoteTerminals[key] === model { model.retire(); remoteTerminals[key] = nil }
            coordinator.refreshRoot()
        }
        remoteTerminals[key] = model
        return model
    }

    /// Ends the terminals of sessions their Mac no longer lists, and of Macs forgotten.
    func pruneRemoteTerminals() {
        for (key, model) in remoteTerminals {
            let listed = remotePeers.peer(model.peer) != nil
                && remotePeers.sessions[model.peer]?.contains(where: { $0.id == model.sessionID }) == true
            guard !listed else { continue }
            model.retire()
            remoteTerminals[key] = nil
        }
    }

    /// The terminal font and theme changed: the paired Macs' terminals here follow it too.
    func restyleRemoteTerminals() {
        for model in remoteTerminals.values { model.setStyle(shell.terminalStyle) }
    }

    func receiveRemote(_ event: ServerEvent) {
        settings?.remote.receive(event)
        if event.type == "remote-host", let service = remotePeers.service {
            Task { [weak self] in
                guard let status = try? await service.status(), let self, remotePeers.service != nil else { return }
                advertiseHost(status)
            }
            return
        }
        guard remotePeers.receive(event), let peer = event.peer else { return }
        // The Mac's events were missed (its stream was down, or lagged there): the chat of it on
        // screen reads its thread again, as this Mac's does after a `reload`.
        if (event.type == "remote-peer" && event.reach == "online") || (event.type == "remote" && event.relayed?["type"]?.string == "reload"),
           case .remoteChat(let shown, _)? = coordinator.chatCoordinator?.destination, shown == peer {
            coordinator.chatCoordinator?.model.page.resync()
        }
        guard event.type == "remote", let relayed = event.relayed,
              let thread = relayed["threadId"]?.string ?? relayed["shell"]?["id"]?.string
        else { return }
        let destination = SidebarDestination.remoteChat(peer: peer, thread: thread)
        switch relayed["type"]?.string {
        case "chat-thread":
            guard let events = relayed["events"]?.array, !events.isEmpty,
                  let chat = coordinator.chatCoordinator, chat.destination == destination else { return }
            chat.model.receive(events: events)
        case "chat-shell":
            if selection == destination, coordinator.chatCoordinator?.destination != destination { coordinator.refreshRoot() }
            guard let chat = coordinator.chatCoordinator, chat.destination == destination else { return }
            chat.model.update(shell: remotePeers.chat(peer: peer, thread: thread), projectName: remotePeers.peer(peer)?.name ?? "")
        case "chat-removed":
            coordinator.remoteChatRemoved(peer: peer, thread: thread)
        default: break
        }
    }

    /// A chat selected before its Mac's chats were read gets its screen; one whose Mac was
    /// forgotten leaves.
    private func remoteRead() {
        pruneRemoteTerminals()
        if case .remoteSession(let peer, let session) = selection {
            if remotePeers.peer(peer) == nil { select(.overview); return }
            guard let listed = remotePeers.sessions[peer] else { return }
            // Selected before its Mac listed it, its screen comes now; removed there, it leaves.
            if listed.contains(where: { $0.id == session }) { coordinator.refreshRoot() } else { select(.overview) }
            return
        }
        guard case .remoteChat(let peer, let thread) = selection else { return }
        if remotePeers.peer(peer) == nil { coordinator.remoteChatRemoved(peer: peer, thread: nil); return }
        if coordinator.chatCoordinator?.destination != selection, remotePeers.chat(peer: peer, thread: thread) != nil {
            coordinator.refreshRoot()
        }
    }

    func makeRemoteChatModel(peer: String, threadID: String) -> ChatViewModel? {
        guard let service = remotePeers.service, let mac = remotePeers.peer(peer),
              let shell = remotePeers.chat(peer: peer, thread: threadID) else { return nil }
        let dark = NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        // The other Mac's folders and home are not this Mac's: the page names the Mac instead.
        let context = ChatPageContext(threadId: threadID, projectId: shell.projectId, cwd: shell.cwd,
                                      projectName: mac.name, appearance: dark ? .dark : .light,
                                      readOnly: true, homeDir: nil)
        let chat = service.chat(peer: peer)
        return chatFactory.chat(threadID: threadID, shell: shell, context: context,
                                backend: ChatServiceBackend(service: { chat }), page: chatScreenPage())
    }

    /// Only a link is followed: a file or a diff the page names is on the other Mac.
    func performRemoteChatAction(_ action: ChatViewModel.Action, peer: String) {
        if case .openLink(let url) = action, ["http", "https"].contains(url.scheme?.lowercased()) { desktop.openBrowser(url) }
    }
}
