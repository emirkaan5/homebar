import Foundation
import Testing
@testable import Core
@testable import HueProvider

@Suite struct HueMapping {
    @Test func decodesLights() throws {
        let url = try #require(Bundle.module.url(forResource: "hue-lights", withExtension: "json", subdirectory: "Fixtures"))
        let json = try JSONValue.parse(Data(contentsOf: url))
        let devices = (json["data"]?.arrayValue ?? []).compactMap(HueMapper.device)
        #expect(devices.count == 2)

        let lamp = try #require(devices.first)
        #expect(lamp.id == "hue:3f2c5a3e-1b0c-4f60-9c1d-7a1c2b3d4e5f")
        #expect(lamp.kind == .light)
        let light = try #require(lamp.lightState)
        #expect(light.isOn)
        #expect(light.brightness == 65)
        #expect(light.mirek == nil)
        #expect(light.mirekRange == 153...500)
        #expect(light.showsColor)
        #expect(light.color == ColorXY(x: 0.4573, y: 0.41))

        let hallway = try #require(devices.last?.lightState)
        #expect(!hallway.isOn)
        #expect(hallway.isDimmable)
        #expect(!hallway.supportsColor)
        #expect(!hallway.supportsTemperature)
    }

    @Test func decodesStreamEvents() {
        let line = #"[{"creationtime":"2026-10-12T22:40:00Z","id":"e1","type":"update","data":[{"id":"abc","type":"light","on":{"on":false},"owner":{"rid":"d","rtype":"device"}},{"id":"abc","type":"light","dimming":{"brightness":42.2}},{"id":"m","type":"motion","motion":{"motion":true}}]}]"#
        let events = HueMapper.events(fromStreamData: line)
        let date = try? Date("2026-10-12T22:40:00Z", strategy: .iso8601)
        #expect(events == [
            .attribute(device: "hue:abc", name: "on", value: "false", date: date),
            .attribute(device: "hue:abc", name: "brightness", value: "42", date: date),
        ])
        #expect(HueMapper.events(fromStreamData: "not json").isEmpty)
    }

    @Test func colourModeClearsTemperature() {
        let attributes = HueMapper.attributes(of: ["color_temperature": ["mirek_valid": .bool(false), "mirek": .null]])
        #expect(attributes["mirek"] == "")
    }

    @Test func commandBodies() throws {
        func text(_ command: DeviceCommand) throws -> String {
            String(decoding: try #require(HueMapper.body(for: command)).data(), as: UTF8.self)
        }
        #expect(try text(.setOn(false, device: "hue:a")) == #"{"on":{"on":false}}"#)
        #expect(try text(.setBrightness(0, device: "hue:a")) == #"{"dimming":{"brightness":1},"on":{"on":true}}"#)
        #expect(try text(.setColorTemperature(mirek: 370, device: "hue:a")) == #"{"color_temperature":{"mirek":370},"on":{"on":true}}"#)
        #expect(try text(.setColor(ColorXY(x: 0.675, y: 0.322), device: "hue:a")) == #"{"color":{"xy":{"x":0.675,"y":0.322}},"on":{"on":true}}"#)
        #expect(HueMapper.body(for: .setLocked(true, device: "hue:a")) == nil)
        #expect(HueMapper.hueID("hue:abc") == "abc")
        #expect(HueMapper.hueID("1000001") == nil)
    }

    @Test func pairingReplies() {
        #expect(HueMapper.pairingReply([["error": ["type": .number(101), "description": "link button not pressed"]]]) == .needsButtonPress)
        #expect(HueMapper.pairingReply([["success": ["username": "key123", "clientkey": "abc"]]]) == .key("key123"))
        #expect(HueMapper.pairingReply([["error": ["type": .number(7), "description": "invalid value"]]]) == .failed("invalid value"))
        #expect(HueMapper.pairingReply(.null) == .failed("The bridge sent an unexpected reply."))
    }

    @Test(arguments: [
        ("192.168.0.20", true), ("10.0.0.5", true), ("172.16.4.1", true), ("172.32.0.1", false),
        ("ecb5fa000000.local", true), ("8.8.8.8", false), ("example.com", false), ("192.168.0", false),
    ])
    func onlyLocalHosts(host: String, isLocal: Bool) {
        #expect(HueMapper.isLocalHost(host) == isLocal)
    }

    @Test func lightStateParsing() {
        let light = LightState(attributes: ["on": "true", "brightness": "150", "mirek": "", "mirek_min": "153", "mirek_max": "500", "color": "bad"])
        #expect(light.brightness == 100)
        #expect(light.mirek == nil)
        #expect(light.color == nil)
        #expect(light.supportsTemperature)
    }
}

@MainActor
@Suite struct CompositeAndLights {
    private func makeStore(lights: MockLights) async -> HomeStore {
        let store = HomeStore(
            provider: CompositeProvider(primary: MockProvider(latency: .milliseconds(10)), accessories: [lights]),
            gate: TestGate(answer: true),
            defaults: UserDefaults(suiteName: "HomeBarTests-\(UUID().uuidString)")!,
            sendDelay: .zero
        )
        await store.start()
        return store
    }

    @Test func mergesDevicesAndRoutesCommands() async throws {
        let lights = MockLights(latency: .milliseconds(10))
        let store = await makeStore(lights: lights)
        #expect(store.thermostats.count == 1)
        #expect(store.lights.map(\.id).contains("hue:mock-bedroom"))
        #expect(store.lights.contains { $0.id == "mock-light" })

        store.send(.setOn(true, device: "hue:mock-bedroom"))
        store.send(.setFanMode(.on, device: MockProvider.thermostatID))
        try await Task.sleep(for: .milliseconds(200))
        #expect(await lights.received == [.setOn(true, device: "hue:mock-bedroom")])
        #expect(store.devices.first { $0.id == "hue:mock-bedroom" }?.lightState?.isOn == true)
        #expect(!store.isPending("hue:mock-bedroom"))
        #expect(store.thermostats.first?.thermostat?.fanMode == .on)
    }

    @Test func unpairedBridgeAddsNothing() async {
        let store = await makeStore(lights: MockLights(paired: false))
        #expect(store.lights.map(\.id) == ["mock-light"])
    }

    @Test func throttlesBrightnessDrags() async throws {
        let lights = MockLights(latency: .milliseconds(10))
        let store = await makeStore(lights: lights)
        // A drag: 30 changes within about 0.3 s.
        for level in stride(from: 10, through: 100, by: 3) {
            store.send(.setBrightness(level, device: "hue:mock-desk"))
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.devices.first { $0.id == "hue:mock-desk" }?.lightState?.brightness == 100)
        try await Task.sleep(for: .milliseconds(600))
        let sent = await lights.received
        #expect(sent.count >= 2 && sent.count <= 5, "sent \(sent.count) commands")
        #expect(sent.last == .setBrightness(100, device: "hue:mock-desk"))
        #expect(!store.isPending("hue:mock-desk"))
        #expect(store.errorMessage == nil)
    }

    @Test func pairingAsksForTheButtonFirst() async throws {
        let lights = MockLights(paired: false)
        #expect(await lights.pairedBridgeName() == nil)
        #expect(try await lights.pair(with: "192.168.0.50") == .needsButtonPress)
        #expect(try await lights.pair(with: "192.168.0.50") == .paired)
        #expect(await lights.pairedBridgeName() == "Demo Hue Bridge")
    }
}
