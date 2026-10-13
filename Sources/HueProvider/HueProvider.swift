import Foundation
import Core

/// Philips Hue lights, through a Hue Bridge on the same network as the Mac.
/// It talks to the bridge directly: no cloud and no Hue account.
public actor HueProvider: AccessoryProvider, BridgeSetup {
    private let api: HueAPI

    public init(secrets: any SecretStore) {
        api = HueAPI(secrets: secrets)
    }

    public nonisolated func owns(_ device: Device.ID) -> Bool {
        device.hasPrefix(HueMapper.prefix)
    }

    public func devices() async throws -> [Device] {
        guard await api.pairedBridge != nil else { return [] }
        return try await api.lights()
    }

    /// Follows the bridge's event stream, and reconnects after 1 s, 2 s, 4 s, … up to 30 s.
    public func updates(for devices: [Device.ID]) async -> AsyncStream<DeviceEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: DeviceEvent.self)
        let api = self.api
        let task = Task {
            var delay: Duration = .seconds(1)
            while !Task.isCancelled, await api.pairedBridge != nil {
                do {
                    try await api.streamEvents { events in
                        events.forEach { continuation.yield($0) }
                    }
                    delay = .seconds(1)
                } catch {
                    // The stream dropped. Wait, then connect again.
                }
                try? await Task.sleep(for: delay)
                delay = min(delay * 2, .seconds(30))
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    public func send(_ command: DeviceCommand) async throws {
        try await api.send(command)
    }

    // MARK: Bridge setup

    public func pairedBridgeName() async -> String? {
        await api.pairedBridge?.name
    }

    public func discover(for duration: Duration) async -> [BridgeCandidate] {
        await HueDiscovery.browse(for: duration)
    }

    public func pair(with host: String) async throws -> PairingResult {
        try await api.pair(host: host)
    }

    public func unpair() async {
        await api.unpair()
    }
}
