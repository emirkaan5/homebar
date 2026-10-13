import Foundation
import Core

struct SessionTokens: Codable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
}

/// Login and REST calls. It is the only type that holds the tokens.
/// It never writes tokens or passwords to a log or to an error message.
actor SmartRentAPI {
    static let baseURL = URL(string: "https://control.smartrent.com/api/v2/")!
    static let socketURL = URL(string: "wss://control.smartrent.com/socket/websocket")!
    static let secretKey = "smartrent.session"

    private let session: URLSession
    private let secrets: any SecretStore
    private var tokens: SessionTokens?
    private var refreshing: Task<SessionTokens, Error>?

    init(secrets: any SecretStore, session: URLSession) {
        self.secrets = secrets
        self.session = session
    }

    // MARK: Session

    func restore() -> Bool {
        guard let data = try? secrets.read(Self.secretKey),
              let saved = try? JSONDecoder().decode(SessionTokens.self, from: data) else { return false }
        tokens = saved
        return true
    }

    func signIn(email: String, password: String) async throws -> SignInResult {
        let body = try await postSession(["email": .string(email), "password": .string(password)])
        if let challenge = body["tfa_api_token"]?.stringValue {
            return .needsTwoFactor(challenge: challenge)
        }
        try store(Self.tokens(from: body))
        return .signedIn
    }

    func completeTwoFactor(challenge: String, code: String) async throws {
        let body = try await postSession(["tfa_api_token": .string(challenge), "token": .string(code)])
        try store(Self.tokens(from: body))
    }

    func signOut() {
        tokens = nil
        try? secrets.delete(Self.secretKey)
    }

    func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let current = tokens else { throw HomeProviderError.sessionExpired }
        let expiresSoon = current.expiresAt.map { $0.timeIntervalSinceNow < 60 } ?? false
        if forceRefresh || expiresSoon {
            return try await refresh().accessToken
        }
        return current.accessToken
    }

    /// The websocket takes the token as a query item, the same as the resident web dashboard.
    func socketURL(forceRefresh: Bool) async throws -> URL {
        var components = URLComponents(url: Self.socketURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "token", value: try await accessToken(forceRefresh: forceRefresh)),
            URLQueryItem(name: "vsn", value: "2.0.0"),
        ]
        return components.url!
    }

    // MARK: Data

    func hubs() async throws -> [JSONValue] {
        try await get("hubs").arrayValue ?? []
    }

    func devices(hub: String) async throws -> [JSONValue] {
        try await get("hubs/\(hub)/devices").arrayValue ?? []
    }

    // MARK: Requests

    private func get(_ path: String) async throws -> JSONValue {
        var retried = false
        while true {
            var request = URLRequest(url: Self.baseURL.appending(path: path))
            request.setValue("Bearer \(try await accessToken(forceRefresh: retried))", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let response = try await Self.perform(request, session: session)
            if response.status == 401 {
                if retried { signOut(); throw HomeProviderError.sessionExpired }
                retried = true
                continue
            }
            guard (200..<300).contains(response.status) else {
                throw HomeProviderError.server(Self.errorMessage(in: response.json) ?? "The request failed (HTTP \(response.status)).")
            }
            return response.json["data"] ?? response.json
        }
    }

    private func postSession(_ body: JSONValue) async throws -> JSONValue {
        var request = URLRequest(url: Self.baseURL.appending(path: "sessions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try body.data()
        let response = try await Self.perform(request, session: session)
        if let message = Self.errorMessage(in: response.json) {
            throw HomeProviderError.invalidCredentials(message)
        }
        guard (200..<300).contains(response.status) else {
            throw HomeProviderError.invalidCredentials("Sign-in failed (HTTP \(response.status)).")
        }
        return response.json["data"] ?? response.json
    }

    /// Gets a new access token. Calls made at the same time share one refresh.
    private func refresh() async throws -> SessionTokens {
        if let refreshing { return try await refreshing.value }
        guard let refreshToken = tokens?.refreshToken else {
            signOut()
            throw HomeProviderError.sessionExpired
        }
        let session = self.session
        let task = Task { try await Self.requestRefresh(refreshToken: refreshToken, session: session) }
        refreshing = task
        defer { refreshing = nil }
        do {
            var fresh = try await task.value
            if fresh.refreshToken == nil { fresh.refreshToken = refreshToken }
            try store(fresh)
            return fresh
        } catch let error as HomeProviderError where error == .offline {
            throw error
        } catch {
            signOut()
            throw HomeProviderError.sessionExpired
        }
    }

    private static func requestRefresh(refreshToken: String, session: URLSession) async throws -> SessionTokens {
        var request = URLRequest(url: baseURL.appending(path: "tokens"))
        request.httpMethod = "POST"
        request.setValue(refreshToken, forHTTPHeaderField: "authorization-x-refresh")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response = try await perform(request, session: session)
        guard (200..<300).contains(response.status), errorMessage(in: response.json) == nil else {
            throw HomeProviderError.sessionExpired
        }
        return try tokens(from: response.json["data"] ?? response.json)
    }

    private func store(_ fresh: SessionTokens) throws {
        tokens = fresh
        try secrets.write(JSONEncoder().encode(fresh), for: Self.secretKey)
    }

    // MARK: Helpers

    private struct Response: Sendable {
        let status: Int
        let json: JSONValue
    }

    private static func perform(_ request: URLRequest, session: URLSession) async throws -> Response {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw error.code == .cancelled ? error : HomeProviderError.offline
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return Response(status: status, json: (try? JSONValue.parse(data)) ?? .null)
    }

    static func tokens(from body: JSONValue) throws -> SessionTokens {
        guard let access = body["access_token"]?.stringValue, !access.isEmpty else {
            throw HomeProviderError.unexpectedResponse("no access token in the login reply")
        }
        let expiresAt = body["expires"]?.stringValue.flatMap(Double.init).map { value -> Date in
            switch value {
            case 1e12...: Date(timeIntervalSince1970: value / 1000)  // milliseconds since 1970
            case 1e9...: Date(timeIntervalSince1970: value)          // seconds since 1970
            default: Date().addingTimeInterval(value)                // seconds from now
            }
        }
        return SessionTokens(accessToken: access, refreshToken: body["refresh_token"]?.stringValue, expiresAt: expiresAt)
    }

    /// Reads the error text from replies such as {"errors": [{"description": "..."}]}.
    static func errorMessage(in json: JSONValue) -> String? {
        let errors = json["errors"] ?? json["error"]
        switch errors {
        case nil, .null?:
            return nil
        case .array(let list)?:
            let messages = list.compactMap { item in
                item["description"]?.stringValue ?? item["detail"]?.stringValue ?? item["message"]?.stringValue ?? item.stringValue
            }
            return messages.isEmpty ? (list.isEmpty ? nil : "The request failed.") : messages.joined(separator: " ")
        case let value?:
            return value.stringValue ?? value["description"]?.stringValue ?? value["message"]?.stringValue ?? "The request failed."
        }
    }
}
