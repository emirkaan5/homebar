import Foundation
import CryptoKit
import Core

/// Trusts the bridge's certificate.
///
/// A Hue Bridge has a self-signed certificate, so the system cannot check it. At
/// pairing the client accepts the certificate it sees and remembers its SHA-256
/// hash (trust on first use). After that it accepts only that certificate, so
/// another device on the network cannot pose as the bridge.
final class HueTrust: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var pinned: String?
    private var lastSeen: String?

    /// nil accepts any certificate, and is only for pairing.
    func pin(_ hash: String?) {
        lock.withLock { pinned = hash }
    }

    /// The hash of the last certificate that a server presented.
    var seenCertificate: String? {
        lock.withLock { lastSeen }
    }

    func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first
        else { return (.performDefaultHandling, nil) }
        let hash = Self.hash(of: leaf)
        let expected: String? = lock.withLock {
            lastSeen = hash
            return pinned
        }
        guard expected == nil || expected == hash else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }

    static func hash(of certificate: SecCertificate) -> String {
        SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Requests to one Hue Bridge on the local network. It is the only type that
/// holds the bridge key, and it never writes the key to a log or an error.
actor HueAPI {
    struct Bridge: Codable, Sendable {
        var id: String
        var name: String
        var host: String
        var appKey: String
        var certificateHash: String
    }

    private static let secretKey = "hue.bridge"

    private let secrets: any SecretStore
    private let trust = HueTrust()
    private let session: URLSession
    private var bridge: Bridge?

    init(secrets: any SecretStore) {
        self.secrets = secrets
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        session = URLSession(configuration: configuration, delegate: trust, delegateQueue: nil)
        if let data = try? secrets.read(Self.secretKey), let saved = try? JSONDecoder().decode(Bridge.self, from: data) {
            bridge = saved
            trust.pin(saved.certificateHash)
        }
    }

    var pairedBridge: Bridge? { bridge }

    // MARK: Pairing

    func pair(host rawHost: String) async throws -> PairingResult {
        let host = rawHost.trimmingCharacters(in: .whitespaces)
        guard HueMapper.isLocalHost(host) else {
            throw HomeProviderError.server("Enter the address of a Hue Bridge on your network, such as 192.168.0.20.")
        }
        // A new pairing starts without a pin, and pins the certificate it sees.
        trust.pin(nil)
        defer { trust.pin(bridge?.certificateHash) }

        var request = URLRequest(url: try url(host: host, path: "/api"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONValue.object(["devicetype": "homebar#mac", "generateclientkey": .bool(true)]).data()
        let reply = try await perform(request)

        switch HueMapper.pairingReply(reply) {
        case .needsButtonPress:
            return .needsButtonPress
        case .failed(let message):
            throw HomeProviderError.server(message)
        case .key(let appKey):
            guard let certificate = trust.seenCertificate else {
                throw HomeProviderError.server("The bridge did not present a certificate.")
            }
            // The name and ID need no key.
            let config = (try? await perform(URLRequest(url: try url(host: host, path: "/api/0/config")))) ?? .null
            let paired = Bridge(
                id: config["bridgeid"]?.stringValue ?? host,
                name: config["name"]?.stringValue ?? "Hue Bridge",
                host: host,
                appKey: appKey,
                certificateHash: certificate
            )
            try secrets.write(JSONEncoder().encode(paired), for: Self.secretKey)
            bridge = paired
            return .paired
        }
    }

    func unpair() {
        bridge = nil
        trust.pin(nil)
        try? secrets.delete(Self.secretKey)
    }

    // MARK: Lights

    func lights() async throws -> [Device] {
        let reply = try await perform(try authorized("/clip/v2/resource/light"))
        if let message = HueMapper.errorMessage(reply) { throw HomeProviderError.server(message) }
        return (reply["data"]?.arrayValue ?? []).compactMap(HueMapper.device)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func send(_ command: DeviceCommand) async throws {
        guard let id = HueMapper.hueID(command.deviceID), let body = HueMapper.body(for: command) else {
            throw HomeProviderError.server("Hue lights cannot do that.")
        }
        var request = try authorized("/clip/v2/resource/light/\(id)")
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try body.data()
        let reply = try await perform(request)
        if let message = HueMapper.errorMessage(reply) { throw HomeProviderError.server(message) }
    }

    /// Reads the bridge's event stream until it ends or fails, and passes on each batch of updates.
    func streamEvents(_ handle: @Sendable ([DeviceEvent]) -> Void) async throws {
        var request = try authorized("/eventstream/clip/v2")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 3600
        let (bytes, response) = try await session.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw HomeProviderError.server("The Hue Bridge refused the event stream.")
        }
        for try await line in bytes.lines where line.hasPrefix("data:") {
            let events = HueMapper.events(fromStreamData: String(line.dropFirst(5)))
            if !events.isEmpty { handle(events) }
        }
    }

    // MARK: Requests

    private func url(host: String, path: String) throws -> URL {
        guard let url = URL(string: "https://\(host)\(path)") else {
            throw HomeProviderError.server("That is not a valid address.")
        }
        return url
    }

    private func authorized(_ path: String) throws -> URLRequest {
        guard let bridge else { throw HomeProviderError.server("No Hue Bridge is paired.") }
        var request = URLRequest(url: try url(host: bridge.host, path: path))
        request.setValue(bridge.appKey, forHTTPHeaderField: "hue-application-key")
        return request
    }

    private func perform(_ request: URLRequest) async throws -> JSONValue {
        let data: Data
        do {
            (data, _) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw HomeProviderError.server("The Hue Bridge presented a different certificate than when it was paired. Remove the bridge and pair it again.")
        } catch {
            throw HomeProviderError.server("Can't reach the Hue Bridge. Check that it is on and on the same network as this Mac.")
        }
        return (try? JSONValue.parse(data)) ?? .null
    }
}
