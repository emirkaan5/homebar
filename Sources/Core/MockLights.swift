import Foundation

/// Fake Hue lights and a fake bridge, for the demo, the interface, and tests.
public actor MockLights: AccessoryProvider, BridgeSetup {
    private var isPaired: Bool
    private var pairAttempts = 0
    private let latency: Duration
    private var lights: [Device.ID: (name: String, attributes: [String: String])]
    private var continuation: AsyncStream<DeviceEvent>.Continuation?
    /// Every command that reached the fake bridge, for tests.
    public private(set) var received: [DeviceCommand] = []

    public init(paired: Bool = true, latency: Duration = .milliseconds(120)) {
        isPaired = paired
        self.latency = latency
        lights = [
            "hue:mock-lamp": ("Living Room Lamp", [
                LightAttribute.on: "true", LightAttribute.brightness: "70",
                LightAttribute.mirek: "", LightAttribute.mirekMinimum: "153", LightAttribute.mirekMaximum: "500",
                LightAttribute.color: "0.5800,0.3900",
            ]),
            "hue:mock-bedroom": ("Bedroom", [
                LightAttribute.on: "false", LightAttribute.brightness: "40",
                LightAttribute.mirek: "366", LightAttribute.mirekMinimum: "153", LightAttribute.mirekMaximum: "454",
            ]),
            "hue:mock-desk": ("Desk Strip", [
                LightAttribute.on: "true", LightAttribute.brightness: "100",
                LightAttribute.mirek: "", LightAttribute.mirekMinimum: "153", LightAttribute.mirekMaximum: "500",
                LightAttribute.color: "0.1600,0.0600",
            ]),
        ]
    }

    public nonisolated func owns(_ device: Device.ID) -> Bool { device.hasPrefix("hue:") }

    public func devices() async throws -> [Device] {
        guard isPaired else { return [] }
        return lights.sorted { $0.value.name < $1.value.name }.map { id, light in
            Device(id: id, name: light.name, kind: .light, rawType: "hue_light", attributes: light.attributes)
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
        guard lights[command.deviceID] != nil else { throw HomeProviderError.server("No such light.") }
        let latency = self.latency
        Task { [weak self] in
            try? await Task.sleep(for: latency)
            await self?.apply(command)
        }
    }

    private func apply(_ command: DeviceCommand) {
        let id = command.deviceID
        set(command.change.name, command.change.value, on: id)
        // Like a real bridge: a new colour leaves white mode, and changing
        // brightness or colour turns the light on.
        switch command {
        case .setColor:
            set(LightAttribute.mirek, "", on: id)
            set(LightAttribute.on, "true", on: id)
        case .setBrightness, .setColorTemperature:
            set(LightAttribute.on, "true", on: id)
        default:
            break
        }
    }

    private func set(_ name: String, _ value: String, on id: Device.ID) {
        guard lights[id]?.attributes[name] != value else { return }
        lights[id]?.attributes[name] = value
        continuation?.yield(.attribute(device: id, name: name, value: value, date: .now))
    }

    // MARK: Bridge setup

    public func pairedBridgeName() async -> String? { isPaired ? "Demo Hue Bridge" : nil }

    public func discover(for duration: Duration) async -> [BridgeCandidate] {
        try? await Task.sleep(for: min(duration, .seconds(1)))
        return [BridgeCandidate(id: "001788FFFE000000", name: "Demo Hue Bridge", host: "192.168.0.50")]
    }

    /// Asks for the button press once, then pairs.
    public func pair(with host: String) async throws -> PairingResult {
        pairAttempts += 1
        if pairAttempts < 2 { return .needsButtonPress }
        isPaired = true
        return .paired
    }

    public func unpair() async {
        isPaired = false
        pairAttempts = 0
    }
}
