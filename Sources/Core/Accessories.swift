import Foundation

/// A second source of devices, such as a Philips Hue Bridge, that sits next to
/// the main account. It has no homes and no sign-in; its devices appear in every home.
public protocol AccessoryProvider: Sendable {
    /// True when this provider controls the device. It must answer without waiting.
    func owns(_ device: Device.ID) -> Bool
    func devices() async throws -> [Device]
    func updates(for devices: [Device.ID]) async -> AsyncStream<DeviceEvent>
    func send(_ command: DeviceCommand) async throws
}

public struct BridgeCandidate: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let host: String

    public init(id: String, name: String, host: String) {
        self.id = id
        self.name = name
        self.host = host
    }
}

public enum PairingResult: Sendable, Equatable {
    case paired
    /// The bridge needs the person to press its link button, then pair again.
    case needsButtonPress
}

/// Finding and pairing a bridge on the local network.
public protocol BridgeSetup: Sendable {
    /// The name of the paired bridge, or nil when none is paired.
    func pairedBridgeName() async -> String?
    func discover(for duration: Duration) async -> [BridgeCandidate]
    func pair(with host: String) async throws -> PairingResult
    func unpair() async
}

/// The main provider plus accessory providers, as one provider. Sign-in and
/// homes come from the main provider. Each command goes to the provider that
/// owns its device.
public struct CompositeProvider: HomeProvider {
    let primary: any HomeProvider
    let accessories: [any AccessoryProvider]

    public init(primary: any HomeProvider, accessories: [any AccessoryProvider]) {
        self.primary = primary
        self.accessories = accessories
    }

    public func restoreSession() async -> Bool { await primary.restoreSession() }

    public func signIn(email: String, password: String) async throws -> SignInResult {
        try await primary.signIn(email: email, password: password)
    }

    public func completeTwoFactor(challenge: String, code: String) async throws {
        try await primary.completeTwoFactor(challenge: challenge, code: code)
    }

    public func signOut() async { await primary.signOut() }

    public func homes() async throws -> [Home] { try await primary.homes() }

    public func devices(in home: Home.ID) async throws -> [Device] {
        var devices = try await primary.devices(in: home)
        for accessory in accessories {
            // A bridge that is unplugged must not hide the rest of the home.
            if let more = try? await accessory.devices() { devices += more }
        }
        return devices
    }

    public func updates(for devices: [Device.ID]) async -> AsyncStream<DeviceEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: DeviceEvent.self)
        let primaryIDs = devices.filter { id in !accessories.contains { $0.owns(id) } }
        let primaryStream = await primary.updates(for: primaryIDs)
        var tasks = [Task {
            for await event in primaryStream { continuation.yield(event) }
            continuation.finish()
        }]
        for accessory in accessories {
            let owned = devices.filter(accessory.owns)
            guard !owned.isEmpty else { continue }
            let accessoryStream = await accessory.updates(for: owned)
            tasks.append(Task {
                // The connection state and the session belong to the main provider.
                for await event in accessoryStream {
                    if case .attribute = event { continuation.yield(event) }
                }
            })
        }
        let running = tasks
        continuation.onTermination = { _ in running.forEach { $0.cancel() } }
        return stream
    }

    public func send(_ command: DeviceCommand) async throws {
        if let accessory = accessories.first(where: { $0.owns(command.deviceID) }) {
            try await accessory.send(command)
        } else {
            try await primary.send(command)
        }
    }

    public func reconnect() async { await primary.reconnect() }
}
