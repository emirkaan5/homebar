import Foundation
import Core

/// The private API that the Alexa app itself uses, for Amazon's smart plugs.
///
/// The session is the one that Amazon's own sign-in page produced (see
/// `AmazonAPI.signInPage`): the app never sees the password. This is the only type
/// that holds the cookies, and it never writes them to a log or an error.
///
/// These calls are unofficial. Every one of them is described, with what is still
/// unverified, in docs/protocol.md.
public actor AmazonAPI {
    struct Session: Codable, Sendable {
        var cookies: [String: String]
        /// The site the person signed in on, such as `amazon.com`.
        var marketplace: String
    }

    static let secretKey = "amazon.session"

    // Change these three lines for another country: for the United Kingdom, use
    // "amazon.co.uk" for the first two, which is where the plug is registered, and
    // the sign-in address follows.
    static let marketplace = "amazon.com"
    static let signInHost = "www.amazon.com"
    /// The API host, `alexa.amazon.com` for the United States.
    public static var alexaHost: String? { AmazonMapper.alexaHost(for: marketplace) }

    /// The page where the person signs in. It belongs to Amazon, so HomeBar never
    /// handles the password, the one-time code, or any captcha.
    public static var signInPage: URL? {
        URL(string: "https://\(signInHost)/ap/signin")
    }

    /// A page to visit after signing in. Amazon issues the cookies its API needs
    /// for this domain when it is first asked for, so the page is opened once.
    public static var sessionPage: URL? {
        alexaHost.flatMap { URL(string: "https://\($0)/") }
    }

    /// Amazon answers a browser user agent and believes an app one much less.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    private let secrets: any SecretStore
    private let http: any AmazonHTTP
    private var session: Session?

    init(secrets: any SecretStore, http: any AmazonHTTP) {
        self.secrets = secrets
        self.http = http
        if let data = try? secrets.read(Self.secretKey), let saved = try? JSONDecoder().decode(Session.self, from: data) {
            session = saved
        }
    }

    // MARK: Session

    var isConnected: Bool { session != nil }

    /// Stores the session that the sign-in page produced.
    func connect(cookies: [String: String]) throws {
        guard !cookies.isEmpty else {
            throw HomeProviderError.server("The Amazon sign-in page did not hand over a session. Try again.")
        }
        let session = Session(cookies: cookies, marketplace: Self.marketplace)
        try secrets.write(try JSONEncoder().encode(session), for: Self.secretKey)
        self.session = session
    }

    func disconnect() {
        session = nil
        try? secrets.delete(Self.secretKey)
    }

    // MARK: Devices

    /// The account's Amazon plugs, with their current state.
    func appliances() async throws -> [Device] {
        guard session != nil else { return [] }
        let devices = AmazonMapper.devices(from: try await get(AmazonMapper.entitiesPath()))
        guard !devices.isEmpty else { return [] }
        // The list of devices does not say whether a plug is on, so ask.
        let entityIDs = devices.compactMap { AmazonMapper.entityID($0.id) }
        guard let states = try? await states(of: entityIDs) else { return devices }
        return devices.map { device in
            var device = device
            guard let entityID = AmazonMapper.entityID(device.id), let on = states[entityID] else { return device }
            device.attributes[SwitchAttribute.on] = on ? "true" : "false"
            return device
        }
    }

    func states(of entityIDs: [String]) async throws -> [String: Bool] {
        guard !entityIDs.isEmpty else { return [:] }
        let body = try AmazonMapper.stateRequest(entityIDs).data()
        return AmazonMapper.states(from: try await perform(path: AmazonMapper.statePath, method: "POST", body: body))
    }

    func setOn(_ on: Bool, entityID: String) async throws {
        let body = try AmazonMapper.controlBody(entityID: entityID, on: on).data()
        _ = try await perform(path: AmazonMapper.statePath, method: "PUT", body: body)
    }

    // MARK: Requests

    private func get(_ path: String) async throws -> JSONValue {
        try await perform(path: path, method: "GET", body: nil)
    }

    private func perform(path: String, method: String, body: Data?) async throws -> JSONValue {
        guard let session, let host = AmazonMapper.alexaHost(for: session.marketplace) else {
            throw HomeProviderError.sessionExpired
        }
        guard let url = URL(string: "https://\(host)\(path)") else {
            throw HomeProviderError.unexpectedResponse("a bad Amazon address")
        }
        var headers = [
            "Accept": "application/json",
            "Accept-Language": "en-US,en;q=0.9",
            "Content-Type": "application/json; charset=UTF-8",
            "DNT": "1",
            "Origin": "https://\(host)",
            "Referer": "https://\(host)/spa/index.html",
            "User-Agent": Self.userAgent,
            "Cookie": cookieHeader(session.cookies),
        ]
        if let csrf = session.cookies["csrf"] { headers["csrf"] = csrf }
        let reply = try await http.send(AmazonRequest(url: url, method: method, headers: headers, body: body))

        switch reply.status {
        case 200..<300:
            break
        case 401, 403:
            // The cookies are dead, so they are dropped: the panel then offers the
            // sign-in again instead of showing an account that no longer answers.
            disconnect()
            throw HomeProviderError.sessionExpired
        case 429:
            throw HomeProviderError.server("Amazon is asking HomeBar to slow down. It tries again at the next update.")
        default:
            throw HomeProviderError.server("Amazon answered with error \(reply.status).")
        }
        return (try? JSONValue.parse(reply.data)) ?? .null
    }

    private func cookieHeader(_ cookies: [String: String]) -> String {
        cookies.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }
}
