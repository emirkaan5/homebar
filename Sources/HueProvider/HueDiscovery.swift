import Foundation
import Network
import Core

/// Finds Hue Bridges on the local network with Bonjour (`_hue._tcp`).
enum HueDiscovery {
    static func browse(for duration: Duration) async -> [BridgeCandidate] {
        let found = Found()
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_hue._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { results, _ in found.set(Array(results)) }
        browser.start(queue: .global(qos: .userInitiated))
        try? await Task.sleep(for: duration)
        browser.cancel()

        var bridges: [BridgeCandidate] = []
        for result in found.results {
            guard case .service(let name, _, _, _) = result.endpoint,
                  let host = await resolve(result.endpoint) else { continue }
            var id = name
            if case .bonjour(let record) = result.metadata, let bridgeID = record["bridgeid"] {
                id = bridgeID
            }
            if !bridges.contains(where: { $0.id == id }) {
                bridges.append(BridgeCandidate(id: id, name: name, host: host))
            }
        }
        return bridges
    }

    /// Connects to a Bonjour service to learn its IPv4 address.
    private static func resolve(_ endpoint: NWEndpoint) async -> String? {
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        let once = Once()
        return await withCheckedContinuation { continuation in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    var host: String?
                    if case .hostPort(let address, _)? = connection.currentPath?.remoteEndpoint,
                       case .ipv4(let ipv4) = address {
                        host = "\(ipv4)"
                    }
                    if once.claim() { continuation.resume(returning: host) }
                    connection.cancel()
                case .failed, .cancelled:
                    if once.claim() { continuation.resume(returning: nil) }
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if once.claim() { continuation.resume(returning: nil) }
                connection.cancel()
            }
        }
    }

    private final class Found: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [NWBrowser.Result] = []
        func set(_ results: [NWBrowser.Result]) { lock.withLock { stored = results } }
        var results: [NWBrowser.Result] { lock.withLock { stored } }
    }

    /// Lets exactly one caller resume a continuation.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.withLock {
                defer { done = true }
                return !done
            }
        }
    }
}
