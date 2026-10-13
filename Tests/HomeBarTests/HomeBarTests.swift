import Foundation
import Testing
@testable import Core
@testable import SmartRentProvider

@Suite struct ThermostatParsing {
    @Test func parsesStringValues() {
        let t = Thermostat(attributes: [
            "current_temp": "71.6", "current_humidity": "0", "heating_setpoint": "68",
            "cooling_setpoint": "None", "mode": "HEAT", "fan_mode": "on", "operating_state": "pending heat",
        ])
        #expect(t.currentTemp == 72)
        #expect(t.humidity == nil)
        #expect(t.heatingSetpoint == 68)
        #expect(t.coolingSetpoint == nil)
        #expect(t.mode == .heat)
        #expect(t.fanMode == .on)
        #expect(t.operatingState == .heating)
    }

    @Test(arguments: [
        ("heating", OperatingState.heating), ("cooling", .cooling), ("fan only", .fanOnly),
        ("idle", .idle), ("off", .idle), ("None", .unknown), ("", .unknown),
    ])
    func operatingStates(raw: String, expected: OperatingState) {
        #expect(OperatingState(raw: raw) == expected)
    }

    @Test func celsiusRange() {
        #expect(Thermostat(attributes: ["heating_setpoint": "20"]).setpointRange == 10...32)
        #expect(Thermostat(attributes: ["heating_setpoint": "68"]).setpointRange == 50...90)
    }
}

@Suite struct SmartRentMessages {
    @Test func decodesFixtureDeviceList() throws {
        let url = try #require(Bundle.module.url(forResource: "device-list", withExtension: "json", subdirectory: "Fixtures"))
        let json = try JSONValue.parse(Data(contentsOf: url))
        let devices = (json["data"]?.arrayValue ?? []).compactMap(DeviceMapper.device)
        #expect(devices.map(\.kind) == [.thermostat, .lock, .leakSensor])
        #expect(devices[0].id == "4821")
        #expect(devices[0].thermostat?.currentTemp == 72)
        #expect(devices[0].thermostat?.operatingState == .unknown)
        #expect(devices[1].isOnline == false)
    }

    @Test func phoenixRoundTrip() throws {
        let message = PhoenixMessage(joinRef: "1", ref: "2", topic: "devices:42", event: "phx_join", payload: [:])
        #expect(try message.text() == #"["1","2","devices:42","phx_join",{}]"#)
        #expect(try PhoenixMessage(text: message.text()) == message)
    }

    @Test func attributeUpdateBecomesEvent() throws {
        let text = #"[null,null,"devices:42","attribute_state",{"device_id":42,"name":"current_temp","last_read_state":"71.5","type":"thermostat"}]"#
        let event = DeviceMapper.event(from: try PhoenixMessage(text: text))
        #expect(event == .attribute(device: "42", name: "current_temp", value: "71.5", date: nil))
    }

    @Test func repliesAreNotDeviceEvents() throws {
        let text = #"["1","1","devices:42","phx_reply",{"status":"ok","response":{}}]"#
        #expect(DeviceMapper.event(from: try PhoenixMessage(text: text)) == nil)
    }

    @Test func commandPayloadUsesNumericID() throws {
        let payload = DeviceMapper.payload(for: .setHeatingSetpoint(70, device: "42"))
        let text = String(decoding: try payload.data(), as: UTF8.self)
        #expect(text == #"{"attributes":[{"name":"heating_setpoint","value":"70"}],"device_id":42}"#)
    }

    @Test func loginReplyTokens() throws {
        let tokens = try SmartRentAPI.tokens(from: ["access_token": "a", "refresh_token": "r", "expires": .number(1_900_000_000)])
        #expect(tokens.accessToken == "a")
        #expect(tokens.refreshToken == "r")
        #expect(tokens.expiresAt == Date(timeIntervalSince1970: 1_900_000_000))
        #expect(throws: HomeProviderError.self) { try SmartRentAPI.tokens(from: ["errors": []]) }
    }

    @Test func errorMessages() {
        #expect(SmartRentAPI.errorMessage(in: ["errors": [["description": "Invalid email or password"]]]) == "Invalid email or password")
        #expect(SmartRentAPI.errorMessage(in: ["errors": .null, "data": [:]]) == nil)
        #expect(SmartRentAPI.errorMessage(in: ["access_token": "a"]) == nil)
    }
}

@MainActor
final class TestGate: ConfirmationGate {
    var answer: Bool
    private(set) var reasons: [String] = []
    init(answer: Bool) { self.answer = answer }
    func confirm(_ reason: String) async -> Bool {
        reasons.append(reason)
        return answer
    }
}

@MainActor
@Suite struct StoreCommands {
    private func makeStore(confirms: Bool, timeout: Duration = .seconds(2), gate: TestGate = TestGate(answer: true)) async -> HomeStore {
        let defaults = UserDefaults(suiteName: "HomeBarTests-\(UUID().uuidString)")!
        let store = HomeStore(
            provider: MockProvider(confirms: confirms, latency: .milliseconds(20)),
            gate: gate,
            defaults: defaults,
            confirmationTimeout: timeout,
            sendDelay: .zero
        )
        await store.start()
        return store
    }

    private var thermostatID: String { MockProvider.thermostatID }

    @Test func loadsMockHome() async {
        let store = await makeStore(confirms: true)
        #expect(store.phase == .ready)
        #expect(store.thermostats.count == 1)
        #expect(store.locks.count == 1)
        #expect(store.lights.count == 1)
        #expect(store.otherDevices.count == 2)
    }

    @Test func confirmedChangeStays() async throws {
        let store = await makeStore(confirms: true)
        store.send(.setMode(.heat, device: thermostatID))
        #expect(store.thermostats.first?.thermostat?.mode == .heat)
        #expect(store.isPending(thermostatID))
        try await Task.sleep(for: .milliseconds(300))
        #expect(!store.isPending(thermostatID))
        #expect(store.thermostats.first?.thermostat?.mode == .heat)
        #expect(store.errorMessage == nil)
    }

    @Test func unconfirmedChangeIsUndone() async throws {
        let store = await makeStore(confirms: false, timeout: .milliseconds(100))
        store.send(.setMode(.heat, device: thermostatID))
        #expect(store.thermostats.first?.thermostat?.mode == .heat)
        try await Task.sleep(for: .milliseconds(400))
        #expect(store.thermostats.first?.thermostat?.mode == .cool)
        #expect(!store.isPending(thermostatID))
        #expect(store.errorMessage != nil)
    }

    @Test func autoModeKeepsDeadband() async {
        let store = await makeStore(confirms: false)
        // The mock starts with heat 68 and cool 71. Heat can go up to 69 only.
        store.adjustSetpoint(.heating, of: thermostatID, by: 5)
        #expect(store.thermostats.first?.thermostat?.heatingSetpoint == 69)
        store.adjustSetpoint(.cooling, of: thermostatID, by: -5)
        #expect(store.thermostats.first?.thermostat?.coolingSetpoint == 71)
    }

    @Test func unlockNeedsConfirmation() async throws {
        let gate = TestGate(answer: false)
        let store = await makeStore(confirms: true, gate: gate)
        await store.setLocked(false, device: "mock-lock")
        #expect(gate.reasons == ["unlock Front Door"])
        #expect(store.locks.first?.doorLock?.isLocked == true)
        #expect(!store.isPending("mock-lock"))

        gate.answer = true
        await store.setLocked(false, device: "mock-lock")
        #expect(store.confirmedValue("locked", of: "mock-lock") == "true")
        try await Task.sleep(for: .milliseconds(300))
        #expect(store.locks.first?.doorLock?.isLocked == false)
        #expect(store.locks.first?.doorLock?.lastEvent?.description == "Unlocked remotely")
    }

    @Test func lockNeedsNoConfirmation() async {
        let gate = TestGate(answer: false)
        let store = await makeStore(confirms: true, gate: gate)
        await store.setLocked(true, device: "mock-lock")
        #expect(gate.reasons.isEmpty)
        #expect(store.isPending("mock-lock"))
    }

    @Test func failedCommandCountsFailure() async throws {
        let store = await makeStore(confirms: false, timeout: .milliseconds(50))
        store.send(.setFanMode(.on, device: thermostatID))
        try await Task.sleep(for: .milliseconds(300))
        #expect(store.failures[thermostatID] == 1)
    }

    @Test func lockEventCodes() {
        #expect(LockEvent(code: "ALARM_TYPE_19_LEVEL_3")?.description == "Unlocked with keypad code 3")
        #expect(LockEvent(code: "ALARM_TYPE_9_LEVEL_0")?.isProblem == true)
        #expect(LockEvent(code: "garbage") == nil)
        #expect(Thermostat(attributes: ["supported_modes": "off,cool,heat"]).supportedModes == [.heat, .cool, .off])
    }

    @Test func lightToggles() async throws {
        let store = await makeStore(confirms: true)
        store.send(.setOn(true, device: "mock-light"))
        #expect(store.isPending("mock-light"))
        try await Task.sleep(for: .milliseconds(300))
        #expect(!store.isPending("mock-light"))
        #expect(store.devices.first { $0.id == "mock-light" }?.attributes["on"] == "true")
        #expect(DeviceMapper.payload(for: .setOn(false, device: "1000001")) ==
                ["device_id": .number(1000001), "attributes": [["name": "on", "value": "false"]]])
    }

    @Test func signInFromThePanel() async {
        let store = HomeStore(provider: MockProvider(signedIn: false, latency: .milliseconds(10)),
                              gate: TestGate(answer: true), defaults: UserDefaults(suiteName: "HomeBarTests-\(UUID().uuidString)")!)
        await store.start()
        #expect(store.phase == .signedOut)

        await store.signIn(email: "me@example.com", password: "")
        #expect(store.phase == .signedOut)
        #expect(store.errorMessage != nil)

        await store.signIn(email: "me@example.com", password: "secret")
        #expect(store.phase == .ready)
        #expect(store.errorMessage == nil)
        #expect(store.thermostats.count == 1)
    }

    @Test func twoFactorFromThePanel() async {
        let store = HomeStore(provider: MockProvider(signedIn: false, latency: .milliseconds(10)),
                              gate: TestGate(answer: true), defaults: UserDefaults(suiteName: "HomeBarTests-\(UUID().uuidString)")!)
        await store.start()
        await store.signIn(email: "2fa@example.com", password: "secret")
        #expect(store.phase == .needsTwoFactor(challenge: "mock-challenge"))

        await store.submitTwoFactor(code: "000000")
        #expect(store.phase == .needsTwoFactor(challenge: "mock-challenge"))
        #expect(store.errorMessage != nil)

        await store.submitTwoFactor(code: "123456")
        #expect(store.phase == .ready)
    }

    @Test func signOutReturnsToSignIn() async {
        let store = await makeStore(confirms: true)
        await store.signOut()
        #expect(store.phase == .signedOut)
        #expect(store.devices.isEmpty)
    }
}
