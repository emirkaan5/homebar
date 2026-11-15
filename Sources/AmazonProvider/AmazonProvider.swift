import Foundation
import Core

/// Amazon's smart plugs, through the private API that the Alexa app uses.
///
/// This is the unofficial path that docs/protocol.md describes: it needs the
/// session from Amazon's own sign-in page, and an Amazon account with the plug
/// already set up. Everything the plug does travels through Amazon's cloud,
/// so it is not local and not instant.
public actor AmazonProvider: AccessoryProvider, AccountSetup {
    private let api: AmazonAPI
    /// How often the plugs are read while nothing changes. Amazon is asked for no
    /// more than this: polling is what gets these sessions limited.
    private let pollInterval: Duration
    /// How long a change is chased before it is left to the panel to report.
    private let confirmationWindow: Duration
    private var continuation: AsyncStream<DeviceEvent>.Continuation?
    /// The last value this provider reported for each device.
    private var reported: [Device.ID: String] = [:]
    /// A change that was sent and has not come back from Amazon yet. While a
    /// device is here, an older value is not reported, so the panel does not
    /// jump back to the old state between the tap and Amazon's answer.
    private var waiting: [Device.ID: (value: String, deadline: ContinuousClock.Instant)] = [:]

    public init(
        secrets: any SecretStore,
        http: any AmazonHTTP = URLSessionHTTP(),
        pollInterval: Duration = .seconds(20),
        confirmationWindow: Duration = .seconds(6)
    ) {
        api = AmazonAPI(secrets: secrets, http: http)
        self.pollInterval = pollInterval
        self.confirmationWindow = confirmationWindow
    }

    public nonisolated func owns(_ device: Device.ID) -> Bool {
        device.hasPrefix(AmazonMapper.prefix)
    }

    public func devices() async throws -> [Device] {
        try await api.appliances()
    }

    /// Amazon has no stream for these plugs, so the state is read on a timer.
    public func updates(for devices: [Device.ID]) async -> AsyncStream<DeviceEvent> {
        continuation?.finish()
        let (stream, continuation) = AsyncStream.makeStream(of: DeviceEvent.self)
        self.continuation = continuation
        let entityIDs = devices.compactMap(AmazonMapper.entityID)
        let interval = pollInterval
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { break }
                if await self.api.isConnected { await self.poll(entityIDs) }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    public func send(_ command: DeviceCommand) async throws {
        guard case .setOn(let on, let deviceID) = command, let entityID = AmazonMapper.entityID(deviceID) else {
            throw HomeProviderError.server("An Amazon plug only turns on and off.")
        }
        try await api.setOn(on, entityID: entityID)

        // Amazon does not push, so the new value is read back until it appears.
        // The panel gives a change 10 s to be confirmed; this stops before that.
        let expected = on ? "true" : "false"
        waiting[deviceID] = (expected, ContinuousClock.now + confirmationWindow)
        defer { waiting[deviceID] = nil }
        while !Task.isCancelled, let pending = waiting[deviceID], ContinuousClock.now < pending.deadline {
            try? await Task.sleep(for: .milliseconds(700))
            guard let states = try? await api.states(of: [entityID]) else { continue }
            guard let value = states[entityID].map({ $0 ? "true" : "false" }), value == expected else { continue }
            report(value, on: deviceID)
            return
        }
    }

    private func poll(_ entityIDs: [String]) async {
        guard !entityIDs.isEmpty, let states = try? await api.states(of: entityIDs) else { return }
        for (entityID, on) in states.sorted(by: { $0.key < $1.key }) {
            let value = on ? "true" : "false"
            guard value != reported[AmazonMapper.deviceID(entityID)] else { continue }
            // While a change is waiting to come back, an older value is not news.
            if let pending = waiting[AmazonMapper.deviceID(entityID)], pending.value != value { continue }
            report(value, on: AmazonMapper.deviceID(entityID))
        }
    }

    private func report(_ value: String, on deviceID: Device.ID) {
        guard reported[deviceID] != value else { return }
        reported[deviceID] = value
        continuation?.yield(.attribute(device: deviceID, name: SwitchAttribute.on, value: value, date: .now))
    }

    // MARK: Sign-in

    public nonisolated var signInPage: URL? { AmazonAPI.signInPage }
    public nonisolated var sessionPage: URL? { AmazonAPI.sessionPage }

    public func connectedAccountName() async -> String? {
        await api.isConnected ? "Amazon" : nil
    }

    public func connect(cookies: [String: String]) async throws {
        try await api.connect(cookies: cookies)
    }

    /// Amazon always has a sign-in page, so only a build without one uses this.
    public func connectDemo() async {}

    public func disconnect() async {
        await api.disconnect()
        reported = [:]
    }
}
