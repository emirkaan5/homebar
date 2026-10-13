import Foundation
import Core

/// Controls devices through the SmartRent cloud with the user's own resident account,
/// with the same login and websocket messages as the resident web dashboard.
public actor SmartRentProvider: HomeProvider {
    private let api: SmartRentAPI
    private let session: URLSession
    private var socket: PhoenixSocket?

    public init(secrets: any SecretStore, session: URLSession = .shared) {
        self.api = SmartRentAPI(secrets: secrets, session: session)
        self.session = session
    }

    /// The Keychain item that holds the session.
    public static let sessionKey = SmartRentAPI.secretKey

    public func restoreSession() async -> Bool {
        await api.restore()
    }

    public func signIn(email: String, password: String) async throws -> SignInResult {
        try await api.signIn(email: email, password: password)
    }

    public func completeTwoFactor(challenge: String, code: String) async throws {
        try await api.completeTwoFactor(challenge: challenge, code: code)
    }

    public func signOut() async {
        await socket?.stop()
        socket = nil
        await api.signOut()
    }

    public func homes() async throws -> [Home] {
        try await api.hubs().compactMap(DeviceMapper.home)
    }

    public func devices(in home: Home.ID) async throws -> [Device] {
        try await api.devices(hub: home)
            .compactMap(DeviceMapper.device)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func updates(for devices: [Device.ID]) async -> AsyncStream<DeviceEvent> {
        await socket?.stop()
        let api = self.api
        let socket = PhoenixSocket(topics: devices.map { "devices:\($0)" }, session: session) { forceRefresh in
            try await api.socketURL(forceRefresh: forceRefresh)
        }
        self.socket = socket

        let (stream, continuation) = AsyncStream.makeStream(of: DeviceEvent.self)
        let pump = Task {
            for await event in socket.events {
                switch event {
                case .state(let state): continuation.yield(.connection(state))
                case .sessionExpired: continuation.yield(.sessionExpired)
                case .message(let message):
                    if let update = DeviceMapper.event(from: message) { continuation.yield(update) }
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in
            pump.cancel()
            Task { await socket.stop() }
        }
        await socket.start()
        return stream
    }

    public func send(_ command: DeviceCommand) async throws {
        guard let socket else { throw HomeProviderError.offline }
        try await socket.push(
            topic: "devices:\(command.deviceID)",
            event: "update_attributes",
            payload: DeviceMapper.payload(for: command)
        )
    }

    /// The raw hub and device JSON, for diagnostics.
    public func rawData() async throws -> (hubs: [JSONValue], devices: [String: [JSONValue]]) {
        let hubs = try await api.hubs()
        var devices: [String: [JSONValue]] = [:]
        for hub in hubs {
            guard let id = hub["id"]?.stringValue else { continue }
            devices[id] = try await api.devices(hub: id)
        }
        return (hubs, devices)
    }

    public func reconnect() async {
        await socket?.reconnectNow()
    }
}
