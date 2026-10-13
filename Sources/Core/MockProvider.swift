import Foundation

/// Fake devices with no account and no network. Use it to build and test the
/// interface and the animations without touching real devices.
public actor MockProvider: HomeProvider {
    private var signedIn: Bool
    private let confirms: Bool
    private let latency: Duration
    private var attributes: [Device.ID: [String: String]]
    private var continuation: AsyncStream<DeviceEvent>.Continuation?
    private var drift: Task<Void, Never>?

    public static let thermostatID = "mock-thermostat"

    /// - Parameters:
    ///   - confirms: false makes the fake thermostat ignore commands, to test the undo path.
    public init(signedIn: Bool = true, confirms: Bool = true, latency: Duration = .milliseconds(600)) {
        self.signedIn = signedIn
        self.confirms = confirms
        self.latency = latency
        attributes = [
            Self.thermostatID: [
                ThermostatAttribute.currentTemp: "74",
                ThermostatAttribute.humidity: "41",
                ThermostatAttribute.heatingSetpoint: "68",
                ThermostatAttribute.coolingSetpoint: "71",
                ThermostatAttribute.mode: "cool",
                ThermostatAttribute.fanMode: "auto",
                ThermostatAttribute.operatingState: "cooling",
                ThermostatAttribute.supportedModes: "heat,cool,auto,off",
            ],
            "mock-lock": ["locked": "true", "notifications": "ALARM_TYPE_21_LEVEL_1"],
            "mock-light": ["on": "false"],
            "mock-leak": ["leak": "false"],
            "mock-motion": ["motion_binary": "false"],
        ]
    }

    public func restoreSession() async -> Bool { signedIn }

    public func signIn(email: String, password: String) async throws -> SignInResult {
        guard !password.isEmpty else { throw HomeProviderError.invalidCredentials("Enter a password.") }
        if email.contains("2fa") { return .needsTwoFactor(challenge: "mock-challenge") }
        signedIn = true
        return .signedIn
    }

    public func completeTwoFactor(challenge: String, code: String) async throws {
        guard code == "123456" else { throw HomeProviderError.invalidCredentials("The code is not correct. Use 123456.") }
        signedIn = true
    }

    public func signOut() async {
        signedIn = false
        continuation?.finish()
    }

    public func homes() async throws -> [Home] {
        guard signedIn else { throw HomeProviderError.sessionExpired }
        return [Home(id: "mock-home", name: "Demo Apartment")]
    }

    public func devices(in home: Home.ID) async throws -> [Device] {
        guard signedIn else { throw HomeProviderError.sessionExpired }
        return [
            Device(id: Self.thermostatID, name: "Living Room", kind: .thermostat, rawType: "thermostat", attributes: attributes[Self.thermostatID] ?? [:]),
            Device(id: "mock-lock", name: "Front Door", kind: .lock, rawType: "entry_control", attributes: attributes["mock-lock"] ?? [:],
                   attributeDates: ["notifications": Date().addingTimeInterval(-25 * 60)], batteryLevel: 82),
            Device(id: "mock-light", name: "Kitchen Light", kind: .switchBinary, rawType: "switch_binary", attributes: attributes["mock-light"] ?? [:]),
            Device(id: "mock-leak", name: "Bathroom - Leak Sensor", kind: .leakSensor, rawType: "sensor_notification", attributes: attributes["mock-leak"] ?? [:]),
            Device(id: "mock-motion", name: "Hallway - Motion Sensor", kind: .motionSensor, rawType: "sensor_notification", attributes: attributes["mock-motion"] ?? [:]),
        ]
    }

    public func updates(for devices: [Device.ID]) async -> AsyncStream<DeviceEvent> {
        continuation?.finish()
        drift?.cancel()
        let (stream, continuation) = AsyncStream.makeStream(of: DeviceEvent.self)
        self.continuation = continuation
        continuation.yield(.connection(.live))
        // The room temperature moves one degree toward the set point now and then.
        drift = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                await self?.driftTemperature()
            }
        }
        continuation.onTermination = { [weak self] _ in
            Task { await self?.cancelDrift() }
        }
        return stream
    }

    public func send(_ command: DeviceCommand) async throws {
        guard signedIn else { throw HomeProviderError.sessionExpired }
        guard confirms else { return }
        let latency = self.latency
        Task { [weak self] in
            try? await Task.sleep(for: latency)
            await self?.apply(command)
        }
    }

    public func reconnect() async {
        continuation?.yield(.connection(.reconnecting))
        continuation?.yield(.connection(.live))
    }

    private func cancelDrift() {
        drift?.cancel()
        drift = nil
    }

    private func apply(_ command: DeviceCommand) {
        set(command.change.name, command.change.value, on: command.deviceID)
        if case .setLocked(let locked, let id) = command {
            set(LockAttribute.notifications, locked ? "ALARM_TYPE_24_LEVEL_1" : "ALARM_TYPE_25_LEVEL_1", on: id)
        }
        updateOperatingState()
    }

    private func driftTemperature() {
        let thermostat = Thermostat(attributes: attributes[Self.thermostatID] ?? [:])
        guard let current = thermostat.currentTemp else { return }
        switch thermostat.operatingState {
        case .heating: set(ThermostatAttribute.currentTemp, String(current + 1), on: Self.thermostatID)
        case .cooling: set(ThermostatAttribute.currentTemp, String(current - 1), on: Self.thermostatID)
        default: return
        }
        updateOperatingState()
    }

    private func updateOperatingState() {
        let thermostat = Thermostat(attributes: attributes[Self.thermostatID] ?? [:])
        guard let current = thermostat.currentTemp else { return }
        let heat = thermostat.heatingSetpoint ?? current
        let cool = thermostat.coolingSetpoint ?? current
        let state: String = switch thermostat.mode {
        case .heat, .auxHeat: current < heat ? "heating" : "idle"
        case .cool: current > cool ? "cooling" : "idle"
        case .auto: current < heat ? "heating" : current > cool ? "cooling" : "idle"
        case .off, nil: "idle"
        }
        if attributes[Self.thermostatID]?[ThermostatAttribute.operatingState] != state {
            set(ThermostatAttribute.operatingState, state, on: Self.thermostatID)
        }
    }

    private func set(_ name: String, _ value: String, on device: Device.ID) {
        attributes[device, default: [:]][name] = value
        continuation?.yield(.attribute(device: device, name: name, value: value, date: .now))
    }
}
