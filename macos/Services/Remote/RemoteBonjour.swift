import dnssd
import Foundation
import Network
import os
import SystemConfiguration

/// The Bonjour service other Macs find this one by, and its TXT keys: `id` (the listener
/// certificate's SHA-256, what a pairing pins), `name` (shown to the other Mac), and `host` and
/// `port` (where its listener answers). `NSBonjourServices` in `App-Info.plist` names the type.
enum RemoteBonjour {
    static let type = "_cascade._tcp"
    /// What Bonjour did, for a Mac nobody can debug: `log show --predicate 'subsystem ==
    /// "com.cascade.app" && category == "remote"'`. The backend's side is in Activity → Remote.
    static let log = Logger(subsystem: "com.cascade.app", category: "remote")

    /// What one Mac advertised.
    struct Sighting: Equatable, Sendable {
        let id: String
        let name: String
        /// `host:port`, as the backend connects to it.
        let address: String
    }

    /// This Mac's name on the local network (`Mac-mini.local`), which every Mac on it resolves.
    static func localHost() -> String? {
        guard let name = SCDynamicStoreCopyLocalHostName(nil) as String?, !name.isEmpty else { return nil }
        return "\(name).local"
    }

    /// The Mac's name as Sharing shows it (`Studio Mac mini`), which the other Mac lists it by.
    static func computerName() -> String? {
        guard let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty else { return nil }
        return name
    }

    /// A DNS-SD TXT record: each entry its length, then `key=value`.
    static func txtRecord(_ entries: [(String, String)]) -> Data {
        var data = Data()
        for (key, value) in entries {
            let entry = Data("\(key)=\(value)".utf8.prefix(255))
            data.append(UInt8(entry.count))
            data.append(entry)
        }
        return data
    }

    /// A sighting from a browse result's TXT entries, or nil when one is missing.
    static func sighting(_ txt: [String: String]) -> Sighting? {
        guard let id = txt["id"], !id.isEmpty, let host = txt["host"], !host.isEmpty,
              let port = txt["port"].flatMap(Int.init), (1...65535).contains(port) else { return nil }
        let name = txt["name"].flatMap { $0.isEmpty ? nil : $0 } ?? host
        return Sighting(id: id, name: name, address: "\(host):\(port)")
    }
}

/// Advertises this Mac while other Macs may connect, so the other Mac lists it without an
/// address typed, and a paired Mac finds it again after its address or port changed. Stops when
/// released.
@MainActor final class RemoteAdvertiser {
    private var service: DNSServiceRef?

    /// Nil when the network has no name for this Mac or Bonjour refused the service.
    init?(name: String, port: Int, fingerprint: String) {
        guard let host = RemoteBonjour.localHost(), (1...65535).contains(port) else {
            RemoteBonjour.log.error("advertise: no local host name, or port \(port, privacy: .public) out of range")
            return nil
        }
        let txt = RemoteBonjour.txtRecord([("id", fingerprint), ("name", name), ("host", host), ("port", String(port))])
        var reference: DNSServiceRef?
        let error = txt.withUnsafeBytes { bytes in
            DNSServiceRegister(&reference, 0, 0, name, RemoteBonjour.type, nil, nil, UInt16(port).bigEndian,
                               UInt16(bytes.count), bytes.baseAddress, Self.registered, nil)
        }
        guard error == kDNSServiceErr_NoError, let reference else {
            RemoteBonjour.log.error("advertise: DNSServiceRegister failed \(error, privacy: .public)")
            return nil
        }
        RemoteBonjour.log.notice("advertise \(name, privacy: .public) at \(host, privacy: .public):\(port, privacy: .public)")
        DNSServiceSetDispatchQueue(reference, .main)
        service = reference
    }

    /// Bonjour's answer, which comes after the call: the name it took, or why it refused
    /// (`-65570` is the local network permission turned off).
    private static let registered: DNSServiceRegisterReply = { _, _, error, name, _, _, _ in
        let name = name.map { String(cString: $0) } ?? ""
        if error == kDNSServiceErr_NoError {
            RemoteBonjour.log.notice("advertised as \(name, privacy: .public)")
        } else {
            RemoteBonjour.log.error("advertise refused: \(error, privacy: .public)")
        }
    }

    func stop() {
        guard let service else { return }
        RemoteBonjour.log.notice("advertise stopped")
        DNSServiceRefDeallocate(service)
        self.service = nil
    }

    isolated deinit { stop() }
}

/// Finds other Macs advertising `RemoteBonjour.type` while it runs: Settings → Remote, open.
@MainActor final class RemoteBrowser {
    private var browser: NWBrowser?
    /// Every Mac seen now, each time the set changes.
    var onChange: ([RemoteBonjour.Sighting]) -> Void = { _ in }

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: RemoteBonjour.type, domain: nil), using: .tcp)
        // Waiting with -65570 (PolicyDenied) is the local network permission turned off.
        browser.stateUpdateHandler = { state in
            switch state {
            case .failed(let error): RemoteBonjour.log.error("browse failed: \(error, privacy: .public)")
            case .waiting(let error): RemoteBonjour.log.error("browse waiting: \(error, privacy: .public)")
            case .ready: RemoteBonjour.log.notice("browse ready")
            default: break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let sightings = results.compactMap { result -> RemoteBonjour.Sighting? in
                guard case .bonjour(let txt) = result.metadata else { return nil }
                return RemoteBonjour.sighting(txt.dictionary)
            }
            let seen = sightings.map { "\($0.name) \($0.address)" }.joined(separator: ", ")
            RemoteBonjour.log.notice("browse sees \(results.count, privacy: .public) (\(sightings.count, privacy: .public) readable): \(seen, privacy: .public)")
            MainActor.assumeIsolated { self?.onChange(sightings) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    isolated deinit { stop() }
}
