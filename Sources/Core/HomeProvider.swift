import Foundation

public enum SignInResult: Sendable, Equatable {
    case signedIn
    /// The account uses two-factor authentication. Pass the challenge back with the code.
    case needsTwoFactor(challenge: String)
}

public enum HomeProviderError: LocalizedError, Sendable, Equatable {
    case invalidCredentials(String)
    case sessionExpired
    case offline
    case server(String)
    case unexpectedResponse(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials(let message): message
        case .sessionExpired: "Your session expired. Sign in again."
        case .offline: "Can't reach the service. Check your internet connection."
        case .server(let message): message
        case .unexpectedResponse(let detail):
            "The service sent a reply that this app does not understand (\(detail)). The service may have changed."
        }
    }
}

/// A back end that controls devices. Only a provider knows a vendor's protocol,
/// so a new back end needs only a new provider.
public protocol HomeProvider: Sendable {
    /// Loads a saved session. Returns false if the user must sign in.
    func restoreSession() async -> Bool
    func signIn(email: String, password: String) async throws -> SignInResult
    func completeTwoFactor(challenge: String, code: String) async throws
    func signOut() async
    func homes() async throws -> [Home]
    func devices(in home: Home.ID) async throws -> [Device]
    /// Opens a live connection for these devices. Ending the stream closes the connection.
    func updates(for devices: [Device.ID]) async -> AsyncStream<DeviceEvent>
    func send(_ command: DeviceCommand) async throws
    /// Drops the live connection and connects again at once, for example after the Mac wakes.
    func reconnect() async
}

/// Asks the person to confirm a dangerous action, such as with Touch ID.
@MainActor
public protocol ConfirmationGate {
    /// `reason` completes the sentence "HomeBar wants to …".
    func confirm(_ reason: String) async -> Bool
}

/// Storage for secrets. The app uses the Keychain; tests use memory.
public protocol SecretStore: Sendable {
    func read(_ key: String) throws -> Data?
    func write(_ data: Data, for key: String) throws
    func delete(_ key: String) throws
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    public init() {}

    public func read(_ key: String) throws -> Data? { lock.withLock { items[key] } }
    public func write(_ data: Data, for key: String) throws { lock.withLock { items[key] = data } }
    public func delete(_ key: String) throws { lock.withLock { items[key] = nil } }
}
