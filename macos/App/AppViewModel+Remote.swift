import AppKit
import Foundation

/// Other Macs: the sidebar's section per paired Mac, its chats shown read-only, and the events its
/// backend relays (`docs/remote/05-mac-to-mac.md`).
extension AppViewModel {
    func connectRemote(_ service: (any RemoteServing)?) {
        remotePeers.onRead = { [weak self] in self?.remoteRead() }
        remotePeers.connect(service)
        settings?.remote.connect(service)
    }

    /// Each paired Mac's section, in the order they were paired.
    func remoteSections() -> [SidebarRemoteSection] {
        remotePeers.peers.map { peer in
            SidebarRemoteSection(peer: peer, sessions: remotePeers.sessions[peer.id] ?? [],
                                 chats: remotePeers.visibleChats(peer.id))
        }
    }

    func remoteChatTitles() -> [SidebarDestination: String] {
        var titles: [SidebarDestination: String] = [:]
        for (peer, chats) in remotePeers.chats {
            for (id, chat) in chats { titles[.remoteChat(peer: peer, thread: id)] = chat.label }
        }
        return titles
    }

    func receiveRemote(_ event: ServerEvent) {
        settings?.remote.receive(event)
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
