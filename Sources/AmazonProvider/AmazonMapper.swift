import Foundation
import Core

/// Turns Amazon's replies into HomeBar devices, and HomeBar commands into Amazon
/// requests. Amazon wraps its values in strings that hold JSON, and the field
/// names differ between device types, so this mapper is tolerant: a missing or
/// unknown field is normal and never a failure.
///
/// Every call here is described in docs/protocol.md.
public enum AmazonMapper {
    /// HomeBar device IDs that belong to the Amazon plugs. The rest of the ID is
    /// the appliance ID that Amazon uses in its own requests.
    public static let prefix = "amazon:"

    /// Amazon's own devices (this plug among them) belong to its first-party skill.
    /// Asking for it lists only Amazon's devices, not the other skills in the account.
    public static let firstPartySkill = "amzn1.ask.1p.smarthome"

    /// The path that lists the smart home devices of the account.
    public static func entitiesPath() -> String {
        "/api/behaviors/entities?skillId=\(firstPartySkill)"
    }

    /// The path that reads and changes device state.
    public static let statePath = "/api/phoenix/state"

    public static func entityID(_ deviceID: Device.ID) -> String? {
        guard deviceID.hasPrefix(prefix) else { return nil }
        let id = String(deviceID.dropFirst(prefix.count))
        return id.isEmpty ? nil : id
    }

    public static func deviceID(_ entityID: String) -> Device.ID { prefix + entityID }

    /// The address of the API for a marketplace: `amazon.com` becomes
    /// `alexa.amazon.com`. Accepts a bare marketplace or a whole address.
    public static func alexaHost(for marketplace: String) -> String? {
        var host = marketplace.lowercased().trimmingCharacters(in: .whitespaces)
        if let address = URL(string: host), let urlHost = address.host { host = urlHost }
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        guard host.hasPrefix("amazon."), host.count > "amazon.".count else { return nil }
        return "alexa." + host
    }

    // MARK: Devices

    /// Every Amazon appliance in a reply to `GET /api/behaviors/entities`.
    public static func devices(from reply: JSONValue) -> [Device] {
        entities(in: reply).compactMap(device(fromEntity:))
    }

    /// The entries of a list reply, whatever the reply wraps them in.
    static func entities(in reply: JSONValue) -> [JSONValue] {
        if let items = reply.arrayValue { return items }
        for key in ["entities", "deviceList", "appliances", "list"] {
            if let items = reply[key]?.arrayValue { return items }
        }
        return firstArray(in: reply) ?? []
    }

    static func firstArray(in value: JSONValue) -> [JSONValue]? {
        if let items = value.arrayValue { return items }
        for child in (value.objectValue ?? [:]).sorted(by: { $0.key < $1.key }).map(\.value) {
            if let found = firstArray(in: child) { return found }
        }
        return nil
    }

    /// One device from one entry of the device list. Amazon puts the appliance ID
    /// and the name under `legacyAppliance` in some replies and at the top level in
    /// others, so both are read.
    static func device(fromEntity entity: JSONValue) -> Device? {
        let type = entity["entityType"]?.stringValue?.uppercased()
        // Scenes, groups and the Echo devices themselves are not plugs.
        guard type == nil || type == "APPLIANCE" else { return nil }
        let appliance = entity["legacyAppliance"] ?? entity["appliance"] ?? .null
        guard let entityID = (appliance["applianceId"] ?? entity["applianceId"] ?? entity["entityId"])?.stringValue,
              !entityID.isEmpty
        else { return nil }
        let name = ((appliance["friendlyName"] ?? entity["friendlyName"] ?? entity["name"])?.stringValue)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "Amazon Plug"
        return Device(
            id: deviceID(entityID),
            name: name,
            kind: .plug,
            rawType: type ?? "APPLIANCE",
            attributes: [:]
        )
    }

    // MARK: State

    /// The on/off state of each appliance in a reply to `POST /api/phoenix/state`.
    /// Amazon sends one entry per capability, each one JSON inside a string.
    public static func states(from reply: JSONValue) -> [String: Bool] {
        var states: [String: Bool] = [:]
        for state in deviceStates(in: reply) {
            guard let entityID = state["entityId"]?.stringValue, let on = powerState(in: state) else { continue }
            states[entityID] = on
        }
        return states
    }

    static func deviceStates(in reply: JSONValue) -> [JSONValue] {
        reply["deviceStates"]?.arrayValue ?? reply.arrayValue ?? []
    }

    static func powerState(in state: JSONValue) -> Bool? {
        let capabilities = state["capabilityStates"]?.arrayValue ?? state["capabilities"]?.arrayValue ?? []
        for capability in capabilities {
            let object = capabilityObject(capability)
            guard object["name"]?.stringValue == "powerState" else { continue }
            let value = object["value"]
            return onValue(value) ?? onValue(value?["value"])
        }
        return nil
    }

    /// A capability arrives either as an object or as a string that holds JSON.
    static func capabilityObject(_ capability: JSONValue) -> JSONValue {
        guard let text = capability.stringValue,
              let data = text.data(using: .utf8),
              let parsed = try? JSONValue.parse(data)
        else { return capability }
        return parsed
    }

    static func onValue(_ value: JSONValue?) -> Bool? {
        switch value?.stringValue?.uppercased() {
        case "ON", "TRUE": true
        case "OFF", "FALSE": false
        default: nil
        }
    }

    // MARK: Commands

    /// The body for a command, or nil when an Amazon plug cannot do it.
    public static func body(for command: DeviceCommand) -> JSONValue? {
        guard case .setOn(let on, let device) = command, let entityID = entityID(device) else { return nil }
        return controlBody(entityID: entityID, on: on)
    }

    public static func controlBody(entityID: String, on: Bool) -> JSONValue {
        [
            "controlRequests": [
                [
                    "entityId": .string(entityID),
                    "entityType": "APPLIANCE",
                    "parameters": ["action": on ? "turnOn" : "turnOff"],
                ]
            ]
        ]
    }

    /// The body that asks for the current state of these appliances.
    public static func stateRequest(_ entityIDs: [String]) -> JSONValue {
        let requests: [JSONValue] = entityIDs.map { entityID in
            ["entityId": .string(entityID), "entityType": "APPLIANCE"]
        }
        return ["stateRequests": .array(requests)]
    }
}
