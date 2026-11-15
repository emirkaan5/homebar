import Foundation

/// Fake Amazon plugs and a fake Amazon session, for the demo, the interface, and
/// tests. It behaves like the real provider: a plug shows up only once the account
/// is connected, and a command comes back as an update a moment later.
public actor MockPlugs: AccessoryProvider, AccountSetup {
    private var isConnected: Bool
    private let latency: Duration
    private var plugs: [Device.ID: (name: String, on: Bool)]
    private var continuation: AsyncStream<DeviceEvent>.Continuation?
    /// Every command that reached the fake plugs, for tests.
    public private(set) var received: [DeviceCommand] = []

    public init(connected: Bool = true, latency: Duration = .milliseconds(120)) {
        isConnected = connected
        self.latency = latency
        plugs = [
            "amazon:amzn1.ask.device.mock-plug": ("Coffee Maker Plug", false),
            "amazon:amzn1.ask.device.mock-lamp-plug": ("Floor Lamp Plug", true),
        ]
    }

    public nonisolated func owns(_ device: Device.ID) -> Bool { device.hasPrefix("amazon:") }

    public func devices() async throws -> [Device] {
        guard isConnected else { return [] }
        return plugs.sorted { $0.value.name < $1.value.name }.map { id, plug in
            Device(
                id: id, name: plug.name, kind: .plug, rawType: "APPLIANCE",
                attributes: [SwitchAttribute.on: plug.on ? "true" : "false"]
            )
        }
    }

    public func updates(for devices: [Device.ID]) async -> AsyncStream<DeviceEvent> {
        continuation?.finish()
        let (stream, continuation) = AsyncStream.makeStream(of: DeviceEvent.self)
        self.continuation = continuation
        return stream
    }

    public func send(_ command: DeviceCommand) async throws {
        received.append(command)
        guard case .setOn(let on, let id) = command, plugs[id] != nil else {
            throw HomeProviderError.server("No such plug.")
        }
        let latency = self.latency
        Task { [weak self] in
            try? await Task.sleep(for: latency)
            await self?.set(on, on: id)
        }
    }

    private func set(_ value: Bool, on id: Device.ID) {
        guard plugs[id]?.on != value else { return }
        plugs[id]?.on = value
        continuation?.yield(.attribute(device: id, name: SwitchAttribute.on, value: value ? "true" : "false", date: .now))
    }

    // MARK: Sign-in

    /// The demo has no sign-in page: the setup offers a button instead.
    public nonisolated var signInPage: URL? { nil }
    public nonisolated var sessionPage: URL? { nil }

    public func connectedAccountName() async -> String? { isConnected ? "Demo Amazon" : nil }

    public func connect(cookies: [String: String]) async throws { isConnected = true }

    public func connectDemo() async { isConnected = true }

    public func disconnect() async {
        isConnected = false
        for id in plugs.keys { plugs[id]?.on = false }
    }
}
