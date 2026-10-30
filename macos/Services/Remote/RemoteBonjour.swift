import dnssd
import Foundation
import Network
import SystemConfiguration

/// The Bonjour service other Macs find this one by, and its TXT keys: `id` (the listener
/// certificate's SHA-256, what a pairing pins), `name` (shown to the other Mac), and `host` and
/// `port` (where its listener answers). `NSBonjourServices` in `App-Info.plist` names the type.
enum RemoteBonjour {
    static let type = "_cascade._tcp"

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

/// Advertises this Mac while a pairing window is open, so the other Mac lists it without an
/// address typed. Stops when released.
@MainActor final class RemoteAdvertiser {
    private var service: DNSServiceRef?

    /// Nil when the network has no name for this Mac or Bonjour refused the service.
    init?(name: String, port: Int, fingerprint: String) {
        guard let host = RemoteBonjour.localHost(), (1...65535).contains(port) else { return nil }
        let txt = RemoteBonjour.txtRecord([("id", fingerprint), ("name", name), ("host", host), ("port", String(port))])
        var reference: DNSServiceRef?
        let error = txt.withUnsafeBytes { bytes in
            DNSServiceRegister(&reference, 0, 0, name, RemoteBonjour.type, nil, nil, UInt16(port).bigEndian,
                               UInt16(bytes.count), bytes.baseAddress, nil, nil)
        }
        guard error == kDNSServiceErr_NoError, let reference else { return nil }
        DNSServiceSetDispatchQueue(reference, .main)
        service = reference
    }

    func stop() {
        guard let service else { return }
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
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let sightings = results.compactMap { result -> RemoteBonjour.Sighting? in
                guard case .bonjour(let txt) = result.metadata else { return nil }
                return RemoteBonjour.sighting(txt.dictionary)
            }
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
