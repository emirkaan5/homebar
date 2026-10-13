import Foundation
import Core

/// Turns SmartRent JSON into Core models. Decoding is tolerant: different hub,
/// lock, and thermostat models send different fields.
enum DeviceMapper {
    static func home(from hub: JSONValue) -> Home? {
        guard let id = hub["id"]?.stringValue else { return nil }
        // SmartRent hubs have no unit name, so most accounts show "Home".
        let candidates: [JSONValue?] = [hub["unit_name"], hub["name"], hub["unit"]?["name"], hub["property_name"]]
        let name = candidates.lazy.compactMap { $0?.stringValue }.first { !$0.isEmpty } ?? "Home"
        return Home(id: id, name: name)
    }

    static func device(from json: JSONValue) -> Device? {
        guard let id = json["id"]?.stringValue else { return nil }
        let type = json["type"]?.stringValue ?? "unknown"
        var attributes: [String: String] = [:]
        var dates: [String: Date] = [:]
        if let list = json["attributes"]?.arrayValue {
            for attribute in list {
                guard let name = attribute["name"]?.stringValue else { continue }
                attributes[name] = [attribute["state"], attribute["last_read_state"], attribute["value"]]
                    .lazy.compactMap { $0?.stringValue }.first ?? ""
                dates[name] = attribute["last_read_at"]?.stringValue.flatMap(parseDate)
            }
        } else if let object = json["attributes"]?.objectValue {
            for (name, value) in object { attributes[name] = value.stringValue ?? "" }
        }
        let name = json["name"]?.stringValue ?? type
        return Device(
            id: id,
            name: name,
            kind: kind(type: type, attributes: attributes),
            rawType: type,
            attributes: attributes,
            attributeDates: dates,
            isOnline: json["online"]?.boolValue ?? true,
            batteryLevel: json["battery_level"]?.stringValue.flatMap { Double($0) }.map { Int($0.rounded()) }
        )
    }

    /// Parses times such as 2026-10-12T19:54:40Z, with or without fractional seconds.
    static func parseDate(_ string: String) -> Date? {
        if let date = try? Date(string, strategy: .iso8601) { return date }
        return try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    static func kind(type: String, attributes: [String: String]) -> DeviceKind {
        switch type {
        case "thermostat": .thermostat
        case "entry_control": .lock
        case "switch_binary": .switchBinary
        case "switch_multilevel": .dimmer
        case "sensor_notification" where attributes["leak"] != nil: .leakSensor
        case "sensor_notification" where attributes["motion_binary"] != nil: .motionSensor
        default: .unknown
        }
    }

    /// Returns the device update in a websocket message, or nil if it is not one.
    static func event(from message: PhoenixMessage) -> DeviceEvent? {
        let prefix = "devices:"
        guard message.topic.hasPrefix(prefix), !message.event.hasPrefix("phx_"),
              let name = message.payload["name"]?.stringValue,
              let value = (message.payload["last_read_state"] ?? message.payload["state"] ?? message.payload["value"])?.stringValue
        else { return nil }
        let id = message.payload["device_id"]?.stringValue ?? String(message.topic.dropFirst(prefix.count))
        let date = message.payload["last_read_at"]?.stringValue.flatMap(parseDate)
        return .attribute(device: id, name: name, value: value, date: date)
    }

    static func payload(for command: DeviceCommand) -> JSONValue {
        let id = command.deviceID
        let change = command.change
        return [
            "device_id": Int(id).map { .number(Double($0)) } ?? .string(id),
            "attributes": [["name": .string(change.name), "value": .string(change.value)]],
        ]
    }
}
