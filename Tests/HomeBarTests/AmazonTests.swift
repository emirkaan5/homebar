import Foundation
import Testing
@testable import Core
@testable import AmazonProvider

private func fixture(_ name: String) throws -> JSONValue {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try JSONValue.parse(Data(contentsOf: url))
}

/// The device and the value of an attribute event, for a test that reads a stream.
private func attribute(_ event: DeviceEvent?) -> (Device.ID, String, String)? {
    guard case .attribute(let device, let name, let value, _)? = event else { return nil }
    return (device, name, value)
}

/// Collects the events of a stream, for a test that must not hang.
private actor Events {
    private(set) var all: [DeviceEvent] = []

    func add(_ event: DeviceEvent) { all.append(event) }
}

@Suite struct AmazonMapping {
    @Test func decodesAppliances() throws {
        let devices = AmazonMapper.devices(from: try fixture("amazon-entities"))
        // A scene, and an entry with no ID at all, are not plugs. An entry with an ID
        // but no name is a plug that keeps Amazon's default name.
        #expect(devices.map(\.name) == ["Coffee Maker", "Floor Lamp", "Amazon Plug"])
        #expect(devices.map(\.id) == [
            "amazon:amzn1.ask.device.REDACTED1", "amazon:amzn1.ask.device.REDACTED2",
            "amazon:amzn1.ask.device.REDACTED4",
        ])
        #expect(devices.allSatisfy { $0.kind == .plug })
        // A plug is switched, and it is not a light.
        #expect(devices.allSatisfy { $0.kind.isSwitch })
        #expect(devices.allSatisfy { !$0.kind.isLight })
        #expect(AmazonMapper.entityID(devices[0].id) == "amzn1.ask.device.REDACTED1")
        #expect(AmazonMapper.entityID("hue:abc") == nil)
        #expect(AmazonMapper.entityID("amazon:") == nil)
    }

    @Test func readsDeviceState() throws {
        let states = AmazonMapper.states(from: try fixture("amazon-state"))
        #expect(states == ["amzn1.ask.device.REDACTED1": true, "amzn1.ask.device.REDACTED2": false])
        // Amazon wraps the capabilities in strings in some replies and in objects in
        // others, and a value is sometimes an object of its own. A state without a
        // power state is left out.
        let nested = JSONValue.object([
            "deviceStates": [
                [
                    "entityId": "a",
                    "capabilityStates": ["{\"name\":\"powerState\",\"value\":{\"value\":\"ON\"}}"],
                ],
                ["entityId": "b", "capabilityStates": ["{\"name\":\"brightness\",\"value\":\"50\"}"]],
            ]
        ])
        #expect(AmazonMapper.states(from: nested) == ["a": true])
        #expect(AmazonMapper.states(from: ["deviceStates": []]).isEmpty)
        #expect(AmazonMapper.states(from: .null).isEmpty)
    }

    @Test func commandBodies() throws {
        func text(_ value: JSONValue) throws -> String {
            String(decoding: try value.data(), as: UTF8.self)
        }
        #expect(try text(#require(AmazonMapper.body(for: .setOn(true, device: "amazon:plug"))))
            == #"{"controlRequests":[{"entityId":"plug","entityType":"APPLIANCE","parameters":{"action":"turnOn"}}]}"#)
        #expect(try text(#require(AmazonMapper.body(for: .setOn(false, device: "amazon:plug"))))
            == #"{"controlRequests":[{"entityId":"plug","entityType":"APPLIANCE","parameters":{"action":"turnOff"}}]}"#)
        #expect(try text(AmazonMapper.stateRequest(["plug"]))
            == #"{"stateRequests":[{"entityId":"plug","entityType":"APPLIANCE"}]}"#)
        #expect(AmazonMapper.entitiesPath() == "/api/behaviors/entities?skillId=amzn1.ask.1p.smarthome")

        // A plug only turns on and off, and only its own devices belong to it.
        #expect(AmazonMapper.body(for: .setBrightness(50, device: "amazon:plug")) == nil)
        #expect(AmazonMapper.body(for: .setOn(true, device: "hue:lamp")) == nil)
    }

    @Test(arguments: [
        ("amazon.com", "alexa.amazon.com"), ("www.amazon.com", "alexa.amazon.com"),
        ("amazon.co.uk", "alexa.amazon.co.uk"), ("https://www.amazon.de/ap/signin", "alexa.amazon.de"),
    ])
    func apiAddress(marketplace: String, host: String) {
        #expect(AmazonMapper.alexaHost(for: marketplace) == host)
    }

    @Test(arguments: ["example.com", "amazon", "amazon.", "alexa.amazon.com", "192.168.0.4"])
    func refusesOtherAddresses(marketplace: String) {
        #expect(AmazonMapper.alexaHost(for: marketplace) == nil)
    }
}

/// A fake Amazon. It holds one plug's state and answers the way docs/protocol.md
/// describes, so the requests this app builds can be checked without a network.
private final class FakeAmazon: AmazonHTTP, @unchecked Sendable {
    private let lock = NSLock()
    private var on: Bool
    private var reported: Bool
    /// How many reads still report the old value after a change, like a plug that
    /// takes a moment to say what it did.
    private var laggingReads = 0
    private let lag: Int
    private var refusedStatus = 200
    private var sent: [AmazonRequest] = []

    init(on: Bool = false, lag: Int = 0) {
        self.on = on
        reported = on
        self.lag = lag
    }

    var requests: [AmazonRequest] { lock.withLock { sent } }
    var isOn: Bool { lock.withLock { on } }
    func refuseEverything(with status: Int) { lock.withLock { refusedStatus = status } }

    func send(_ request: AmazonRequest) async throws -> AmazonReply {
        let refused: Int = lock.withLock {
            sent.append(request)
            return refusedStatus
        }
        guard refused == 200 else { return AmazonReply(data: Data("{}".utf8), status: refused) }

        switch (request.method, request.url.path) {
        case ("GET", "/api/behaviors/entities"):
            let url = try #require(
                Bundle.module.url(forResource: "amazon-entities", withExtension: "json", subdirectory: "Fixtures")
            )
            return AmazonReply(data: try Data(contentsOf: url), status: 200)

        case ("PUT", "/api/phoenix/state"):
            let body = (try? JSONValue.parse(request.body ?? Data())) ?? .null
            let action = body["controlRequests"]?.arrayValue?.first?["parameters"]?["action"]?.stringValue
            lock.withLock {
                on = action == "turnOn"
                laggingReads = lag
            }
            return AmazonReply(data: Data("{}".utf8), status: 200)

        default:
            let value = lock.withLock { () -> Bool in
                if laggingReads > 0 { laggingReads -= 1 } else { reported = on }
                return reported
            }
            let capability = "{\"namespace\":\"Alexa.PowerController\",\"name\":\"powerState\",\"value\":\"\(value ? "ON" : "OFF")\"}"
            let reply = JSONValue.object([
                "deviceStates": [
                    [
                        "entityId": "amzn1.ask.device.REDACTED1",
                        "entityType": "APPLIANCE",
                        "capabilityStates": [.string(capability)],
                    ]
                ]
            ])
            return AmazonReply(data: (try? reply.data()) ?? Data(), status: 200)
        }
    }
}

@Suite struct AmazonPlugs {
    private func connected(_ fake: FakeAmazon, window: Duration = .seconds(3)) async throws -> AmazonProvider {
        let provider = AmazonProvider(secrets: InMemorySecretStore(), http: fake, confirmationWindow: window)
        try await provider.connect(cookies: ["session-id": "abc", "csrf": "token"])
        return provider
    }

    @Test func readsPlugsWithTheirState() async throws {
        let fake = FakeAmazon(on: true)
        let provider = try await connected(fake)
        let devices = try await provider.devices()
        #expect(devices.map(\.name) == ["Coffee Maker", "Floor Lamp", "Amazon Plug"])
        #expect(devices.first?.attributes[SwitchAttribute.on] == "true")
        // The reply holds one plug's state only, so the others have none until the
        // next reading.
        #expect(devices.dropFirst().allSatisfy { $0.attributes[SwitchAttribute.on] == nil })

        let request = try #require(fake.requests.first)
        #expect(request.method == "GET")
        #expect(request.url.absoluteString == "https://alexa.amazon.com/api/behaviors/entities?skillId=amzn1.ask.1p.smarthome")
        // The session travels in the cookie header, and Amazon asks for the token too.
        #expect(request.headers["Cookie"] == "csrf=token; session-id=abc")
        #expect(request.headers["csrf"] == "token")
        #expect(request.headers["Referer"] == "https://alexa.amazon.com/spa/index.html")
        #expect(request.headers["Origin"] == "https://alexa.amazon.com")
    }

    @Test func sendsAChangeAndReportsItBack() async throws {
        let fake = FakeAmazon()
        let provider = try await connected(fake)
        let devices = try await provider.devices()
        let plug = try #require(devices.first).id

        let stream = await provider.updates(for: devices.map(\.id))
        let events = Events()
        let collecting = Task { for await event in stream { await events.add(event) } }
        try await provider.send(.setOn(true, device: plug))
        try await Task.sleep(for: .milliseconds(300))
        collecting.cancel()

        #expect(fake.isOn)
        let put = try #require(fake.requests.last { $0.method == "PUT" })
        #expect(String(decoding: put.body ?? Data(), as: UTF8.self)
            == #"{"controlRequests":[{"entityId":"amzn1.ask.device.REDACTED1","entityType":"APPLIANCE","parameters":{"action":"turnOn"}}]}"#)
        // The change comes back as an update, which is what the panel waits for.
        #expect(await events.all.count == 1)
        let reported = try #require(attribute(await events.all.first))
        #expect(reported == (plug, SwitchAttribute.on, "true"))
    }

    @Test func waitsForALaggingPlug() async throws {
        let fake = FakeAmazon(lag: 1)
        let provider = try await connected(fake)
        let devices = try await provider.devices()
        try await provider.send(.setOn(true, device: try #require(devices.first).id))
        #expect(fake.isOn)
    }

    @Test func dropsASessionThatAmazonRefuses() async throws {
        let secrets = InMemorySecretStore()
        let fake = FakeAmazon()
        let provider = AmazonProvider(secrets: secrets, http: fake)
        try await provider.connect(cookies: ["session-id": "abc"])
        #expect(try secrets.read(AmazonAPI.secretKey) != nil)

        fake.refuseEverything(with: 401)
        await #expect(throws: HomeProviderError.sessionExpired) { _ = try await provider.devices() }
        // Dead cookies are dropped, so the panel offers the sign-in again.
        #expect(try secrets.read(AmazonAPI.secretKey) == nil)
        #expect(await provider.connectedAccountName() == nil)
    }

    @Test func reportsAMissingAccount() async throws {
        let provider = AmazonProvider(secrets: InMemorySecretStore(), http: FakeAmazon())
        #expect(try await provider.devices().isEmpty)
        #expect(await provider.connectedAccountName() == nil)
        #expect(AmazonAPI.signInPage?.absoluteString == "https://www.amazon.com/ap/signin")
        #expect(AmazonAPI.sessionPage?.absoluteString == "https://alexa.amazon.com/")
    }

    @MainActor
    @Test func thePanelConfirmsAPlugChange() async throws {
        let provider = try await connected(FakeAmazon())
        let store = HomeStore(
            provider: CompositeProvider(primary: MockProvider(latency: .milliseconds(10)), accessories: [provider]),
            gate: TestGate(answer: true),
            defaults: UserDefaults(suiteName: "HomeBarTests-\(UUID().uuidString)")!,
            sendDelay: .zero
        )
        await store.start()
        let plug = try #require(store.devices.first { $0.kind == .plug })
        // A plug has a tile of its own, next to the other devices, not in the lights.
        #expect(store.otherDevices.map(\.id).contains(plug.id))
        #expect(!store.lights.map(\.id).contains(plug.id))

        store.send(.setOn(true, device: plug.id))
        try await Task.sleep(for: .milliseconds(1500))
        #expect(store.devices.first { $0.id == plug.id }?.attributes[SwitchAttribute.on] == "true")
        #expect(!store.isPending(plug.id))
        #expect(store.errorMessage == nil)
    }
}
