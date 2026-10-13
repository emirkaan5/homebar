import Foundation
import Observation

/// The state that the interface reads. The interface never talks to the network:
/// it calls the store, and the store calls the provider.
@MainActor
@Observable
public final class HomeStore {
    public enum Phase: Equatable {
        case starting
        case signedOut
        case needsTwoFactor(challenge: String)
        case loading
        case ready
    }

    public struct PendingKey: Hashable, Sendable {
        public let device: Device.ID
        public let attribute: String
    }

    public private(set) var phase: Phase = .starting
    public private(set) var homes: [Home] = []
    public private(set) var selectedHomeID: Home.ID?
    public private(set) var devices: [Device] = []
    public private(set) var connection: ConnectionState = .offline
    /// Changes that the panel shows but the device has not confirmed yet.
    public private(set) var pending: Set<PendingKey> = []
    public private(set) var isBusy = false
    /// Counts failed commands per device. The interface watches it to play a failure animation.
    public private(set) var failures: [Device.ID: Int] = [:]
    public var errorMessage: String?

    private let provider: any HomeProvider
    private let gate: any ConfirmationGate
    private let defaults: UserDefaults
    private let confirmationTimeout: Duration
    private let sendDelay: Duration
    private var updatesTask: Task<Void, Never>?
    /// The last confirmed value of each pending attribute, used to undo a change that fails.
    private var confirmed: [PendingKey: String?] = [:]
    /// Debounced commands that wait for the value to stop changing.
    private var waitingToSend: [PendingKey: Task<Void, Never>] = [:]
    /// Throttled commands that are being sent while a drag goes on, and the newest
    /// command for each, which the throttle sends next.
    private var throttles: [PendingKey: Task<Void, Never>] = [:]
    private var latest: [PendingKey: DeviceCommand] = [:]
    private var timeouts: [PendingKey: Task<Void, Never>] = [:]

    private static let selectedHomeKey = "selectedHomeID"

    public init(
        provider: any HomeProvider,
        gate: any ConfirmationGate,
        defaults: UserDefaults = .standard,
        confirmationTimeout: Duration = .seconds(10),
        sendDelay: Duration = .milliseconds(700)
    ) {
        self.provider = provider
        self.gate = gate
        self.defaults = defaults
        self.confirmationTimeout = confirmationTimeout
        self.sendDelay = sendDelay
    }

    public var selectedHome: Home? { homes.first { $0.id == selectedHomeID } }
    public var thermostats: [Device] { devices.filter { $0.kind == .thermostat } }
    public var locks: [Device] { devices.filter { $0.kind == .lock } }
    public var lights: [Device] { devices.filter { $0.kind.isLight } }
    /// Sensors and other devices that have no card of their own.
    public var otherDevices: [Device] { devices.filter { $0.kind != .thermostat && $0.kind != .lock && !$0.kind.isLight } }

    public func isPending(_ device: Device.ID) -> Bool {
        pending.contains { $0.device == device }
    }

    public func isPending(_ device: Device.ID, attribute: String) -> Bool {
        pending.contains(PendingKey(device: device, attribute: attribute))
    }

    /// The last value the device confirmed. While a change is pending this is
    /// the value from before the change, not the value on screen.
    public func confirmedValue(_ attribute: String, of deviceID: Device.ID) -> String? {
        let key = PendingKey(device: deviceID, attribute: attribute)
        if pending.contains(key), let previous = confirmed[key] { return previous }
        return devices.first { $0.id == deviceID }?.attributes[attribute]
    }

    // MARK: Session

    public func start() async {
        if await provider.restoreSession() {
            await loadHomes()
        } else {
            phase = .signedOut
        }
    }

    public func signIn(email: String, password: String) async {
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        do {
            switch try await provider.signIn(email: email, password: password) {
            case .signedIn: await loadHomes()
            case .needsTwoFactor(let challenge): phase = .needsTwoFactor(challenge: challenge)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func submitTwoFactor(code: String) async {
        guard case .needsTwoFactor(let challenge) = phase else { return }
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        do {
            try await provider.completeTwoFactor(challenge: challenge, code: code)
            await loadHomes()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func signOut() async {
        await provider.signOut()
        resetToSignedOut()
    }

    // MARK: Homes and devices

    public func select(home id: Home.ID) async {
        selectedHomeID = id
        defaults.set(id, forKey: Self.selectedHomeKey)
        await loadDevices()
    }

    public func reload() async {
        await loadDevices()
    }

    public func reconnect() async {
        await provider.reconnect()
    }

    private func loadHomes() async {
        phase = .loading
        do {
            homes = try await provider.homes()
            let saved = defaults.string(forKey: Self.selectedHomeKey)
            selectedHomeID = homes.first { $0.id == saved }?.id ?? homes.first?.id
            await loadDevices()
        } catch {
            handle(error)
        }
    }

    private func loadDevices() async {
        stopUpdates()
        guard let home = selectedHomeID else {
            devices = []
            phase = .ready
            return
        }
        do {
            devices = try await provider.devices(in: home)
            phase = .ready
            startUpdates()
        } catch {
            handle(error)
        }
    }

    /// Gets the full state again after the connection comes back, without
    /// overwriting changes that are still pending.
    private func refreshAttributes() async {
        guard let home = selectedHomeID, let fresh = try? await provider.devices(in: home) else { return }
        for device in fresh {
            guard let index = devices.firstIndex(where: { $0.id == device.id }) else { continue }
            for (name, value) in device.attributes where !pending.contains(PendingKey(device: device.id, attribute: name)) {
                devices[index].attributes[name] = value
            }
            devices[index].isOnline = device.isOnline
        }
    }

    private func startUpdates() {
        let ids = devices.map(\.id)
        let provider = self.provider
        updatesTask = Task { [weak self] in
            let stream = await provider.updates(for: ids)
            for await event in stream {
                self?.apply(event)
            }
        }
    }

    private func stopUpdates() {
        updatesTask?.cancel()
        updatesTask = nil
        connection = .offline
    }

    private func apply(_ event: DeviceEvent) {
        switch event {
        case .connection(let state):
            let cameBack = state == .live && connection == .reconnecting
            connection = state
            if cameBack { Task { await refreshAttributes() } }

        case .attribute(let id, let name, let value, let date):
            guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
            devices[index].attributeDates[name] = date ?? .now
            let key = PendingKey(device: id, attribute: name)
            if waitingToSend[key] != nil || throttles[key] != nil {
                // The user is still adjusting this value. Keep their value on screen.
                confirmed[key] = value
                return
            }
            devices[index].attributes[name] = value
            if pending.contains(key) { finish(key) }

        case .sessionExpired:
            resetToSignedOut()
            errorMessage = HomeProviderError.sessionExpired.errorDescription
        }
    }

    // MARK: Commands

    /// Shows the change at once, then sends it. If the device does not confirm
    /// the change in time, the panel goes back to the last confirmed value.
    public func send(_ command: DeviceCommand) {
        let change = command.change
        let key = PendingKey(device: command.deviceID, attribute: change.name)
        guard let index = devices.firstIndex(where: { $0.id == key.device }) else { return }

        if !pending.contains(key) { confirmed[key] = devices[index].attributes[change.name] }
        devices[index].attributes[change.name] = change.value
        pending.insert(key)
        errorMessage = nil
        timeouts.removeValue(forKey: key)?.cancel()

        switch command.timing {
        case .immediate:
            waitingToSend.removeValue(forKey: key)?.cancel()
            Task { [weak self] in
                if await self?.deliver(command, key: key) == true {
                    self?.armTimeout(for: key, after: command.confirmationTimeout)
                }
            }

        case .debounce:
            waitingToSend.removeValue(forKey: key)?.cancel()
            let delay = sendDelay
            waitingToSend[key] = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                self?.waitingToSend[key] = nil
                if await self?.deliver(command, key: key) == true {
                    self?.armTimeout(for: key, after: command.confirmationTimeout)
                }
            }

        case .throttle(let interval):
            latest[key] = command
            guard throttles[key] == nil else { return }  // The running throttle sends it next.
            throttles[key] = Task { [weak self] in
                var sent: DeviceCommand?
                while let next = self?.latest[key], next != sent {
                    sent = next
                    guard await self?.deliver(next, key: key) == true else { break }
                    try? await Task.sleep(for: interval)
                }
                self?.endThrottle(key, lastSent: sent)
            }
        }
    }

    /// Sends a command. If it cannot be sent, undoes the change and returns false.
    private func deliver(_ command: DeviceCommand, key: PendingKey) async -> Bool {
        do {
            try await provider.send(command)
            return true
        } catch {
            revert(key, message: error.localizedDescription)
            return false
        }
    }

    private func endThrottle(_ key: PendingKey, lastSent: DeviceCommand?) {
        throttles[key] = nil
        latest[key] = nil
        guard pending.contains(key) else { return }
        // The device may have confirmed the last value while the drag went on.
        if let lastSent, confirmed[key].flatMap({ $0 }) == lastSent.change.value {
            finish(key)
        } else {
            armTimeout(for: key, after: lastSent?.confirmationTimeout)
        }
    }

    /// Moves a set point by `delta` degrees.
    public func adjustSetpoint(_ kind: SetpointKind, of deviceID: Device.ID, by delta: Int) {
        guard let current = devices.first(where: { $0.id == deviceID })?.thermostat?.setpoint(kind) else { return }
        setSetpoint(kind, of: deviceID, to: current + delta)
    }

    /// The values a set point can take now: the thermostat's range, less the
    /// auto-mode gap that must stay between heat and cool.
    public func setpointRange(_ kind: SetpointKind, of deviceID: Device.ID) -> ClosedRange<Int>? {
        guard let thermostat = devices.first(where: { $0.id == deviceID })?.thermostat else { return nil }
        var range = thermostat.setpointRange
        switch kind {
        case .heating:
            if let cool = thermostat.coolingSetpoint {
                range = range.lowerBound...max(range.lowerBound, min(range.upperBound, cool - Thermostat.minimumDeadband))
            }
        case .cooling:
            if let heat = thermostat.heatingSetpoint {
                range = min(range.upperBound, max(range.lowerBound, heat + Thermostat.minimumDeadband))...range.upperBound
            }
        }
        return range
    }

    /// Sets a set point, limited to `setpointRange`. Returns the value that was set.
    @discardableResult
    public func setSetpoint(_ kind: SetpointKind, of deviceID: Device.ID, to requested: Int) -> Int? {
        guard let range = setpointRange(kind, of: deviceID),
              let current = devices.first(where: { $0.id == deviceID })?.thermostat?.setpoint(kind) else { return nil }
        let value = min(max(requested, range.lowerBound), range.upperBound)
        if value != current {
            send(kind == .heating ? .setHeatingSetpoint(value, device: deviceID) : .setCoolingSetpoint(value, device: deviceID))
        }
        return value
    }

    /// Locks at once. Unlocking asks for Touch ID or the Mac password first.
    /// A failed unlock is never sent again automatically.
    public func setLocked(_ locked: Bool, device deviceID: Device.ID) async {
        guard let device = devices.first(where: { $0.id == deviceID }) else { return }
        if !locked {
            guard await gate.confirm("unlock \(device.name)") else { return }
        }
        send(.setLocked(locked, device: deviceID))
    }

    private func armTimeout(for key: PendingKey, after duration: Duration?) {
        guard pending.contains(key) else { return }
        let timeout = duration ?? confirmationTimeout
        timeouts[key] = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self else { return }
            let name = self.devices.first { $0.id == key.device }?.name ?? "The device"
            self.revert(key, message: "\(name) did not confirm the change.")
        }
    }

    private func revert(_ key: PendingKey, message: String) {
        guard pending.contains(key) else { return }
        if let index = devices.firstIndex(where: { $0.id == key.device }), let previous = confirmed[key] {
            devices[index].attributes[key.attribute] = previous
        }
        finish(key)
        failures[key.device, default: 0] += 1
        errorMessage = message
    }

    private func finish(_ key: PendingKey) {
        pending.remove(key)
        confirmed[key] = nil
        timeouts.removeValue(forKey: key)?.cancel()
    }

    private func handle(_ error: Error) {
        if (error as? HomeProviderError) == .sessionExpired {
            resetToSignedOut()
        } else {
            phase = .ready
        }
        errorMessage = error.localizedDescription
    }

    private func resetToSignedOut() {
        stopUpdates()
        waitingToSend.values.forEach { $0.cancel() }
        throttles.values.forEach { $0.cancel() }
        timeouts.values.forEach { $0.cancel() }
        waitingToSend = [:]
        throttles = [:]
        latest = [:]
        timeouts = [:]
        pending = []
        confirmed = [:]
        homes = []
        devices = []
        selectedHomeID = nil
        phase = .signedOut
    }
}
