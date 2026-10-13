import Foundation
import Core

/// Turns Hue API v2 (CLIP v2) JSON into Core models, and commands into request bodies.
enum HueMapper {
    /// Hue IDs are UUIDs. The prefix marks a device as a Hue light.
    static let prefix = "hue:"

    static func deviceID(_ hueID: String) -> Device.ID { prefix + hueID }

    static func hueID(_ deviceID: Device.ID) -> String? {
        deviceID.hasPrefix(prefix) ? String(deviceID.dropFirst(prefix.count)) : nil
    }

    // MARK: Lights

    /// A light from `GET /clip/v2/resource/light`.
    static func device(from light: JSONValue) -> Device? {
        guard light["type"]?.stringValue == "light", let id = light["id"]?.stringValue else { return nil }
        var attributes = attributes(of: light)
        if attributes[LightAttribute.on] == nil { attributes[LightAttribute.on] = "false" }
        return Device(
            id: deviceID(id),
            name: light["metadata"]?["name"]?.stringValue ?? "Hue light",
            kind: .light,
            rawType: "hue_light",
            attributes: attributes
        )
    }

    /// The attributes in a light, or in a light update, which has only the fields that changed.
    static func attributes(of light: JSONValue) -> [String: String] {
        var attributes: [String: String] = [:]
        if let on = light["on"]?["on"]?.boolValue {
            attributes[LightAttribute.on] = on ? "true" : "false"
        }
        if let brightness = light["dimming"]?["brightness"], case .number(let level) = brightness {
            attributes[LightAttribute.brightness] = String(Int(max(1, min(100, level.rounded()))))
        }
        if let temperature = light["color_temperature"] {
            // mirek_valid is false while the light shows a colour.
            if temperature["mirek_valid"]?.boolValue == false {
                attributes[LightAttribute.mirek] = ""
            } else if let mirek = temperature["mirek"]?.stringValue {
                attributes[LightAttribute.mirek] = mirek
            }
            if let schema = temperature["mirek_schema"],
               let low = schema["mirek_minimum"]?.stringValue, let high = schema["mirek_maximum"]?.stringValue {
                attributes[LightAttribute.mirekMinimum] = low
                attributes[LightAttribute.mirekMaximum] = high
            }
        }
        if let xy = light["color"]?["xy"],
           case .number(let x)? = xy["x"], case .number(let y)? = xy["y"] {
            attributes[LightAttribute.color] = ColorXY(x: x, y: y).text
        }
        return attributes
    }

    // MARK: Events

    /// The device updates in one `data:` line of `/eventstream/clip/v2`.
    static func events(fromStreamData text: String) -> [DeviceEvent] {
        guard let batches = (try? JSONValue.parse(Data(text.utf8)))?.arrayValue else { return [] }
        var events: [DeviceEvent] = []
        for batch in batches where batch["type"]?.stringValue == "update" {
            let date = batch["creationtime"]?.stringValue.flatMap { try? Date($0, strategy: .iso8601) }
            for item in batch["data"]?.arrayValue ?? [] where item["type"]?.stringValue == "light" {
                guard let id = item["id"]?.stringValue else { continue }
                for (name, value) in attributes(of: item).sorted(by: { $0.key < $1.key }) {
                    events.append(.attribute(device: deviceID(id), name: name, value: value, date: date))
                }
            }
        }
        return events
    }

    // MARK: Commands

    /// The body for `PUT /clip/v2/resource/light/{id}`, or nil if Hue has no such command.
    /// Changing brightness or colour also turns the light on, as people expect.
    static func body(for command: DeviceCommand) -> JSONValue? {
        switch command {
        case .setOn(let on, _):
            return ["on": ["on": .bool(on)]]
        case .setBrightness(let level, _):
            return ["on": ["on": .bool(true)], "dimming": ["brightness": .number(Double(max(1, min(100, level))))]]
        case .setColorTemperature(let mirek, _):
            return ["on": ["on": .bool(true)], "color_temperature": ["mirek": .number(Double(mirek))]]
        case .setColor(let color, _):
            return ["on": ["on": .bool(true)], "color": ["xy": ["x": .number(color.x), "y": .number(color.y)]]]
        default:
            return nil
        }
    }

    // MARK: Pairing

    enum PairingReply: Equatable {
        case key(String)
        case needsButtonPress
        case failed(String)
    }

    /// The reply to `POST /api`: `[{"success": {"username": …}}]` or `[{"error": {"type": 101, …}}]`.
    static func pairingReply(_ json: JSONValue) -> PairingReply {
        guard let first = json.arrayValue?.first else { return .failed("The bridge sent an unexpected reply.") }
        if let key = first["success"]?["username"]?.stringValue, !key.isEmpty {
            return .key(key)
        }
        if let error = first["error"] {
            if error["type"]?.stringValue == "101" { return .needsButtonPress }
            return .failed(error["description"]?.stringValue ?? "The bridge refused to pair.")
        }
        return .failed("The bridge sent an unexpected reply.")
    }

    /// The first error in a CLIP v2 reply, if any.
    static func errorMessage(_ json: JSONValue) -> String? {
        json["errors"]?.arrayValue?.first.map { $0["description"]?.stringValue ?? "The bridge refused the command." }
    }

    /// Only hosts on the local network: private IPv4 addresses and `.local` names.
    /// The bridge key and the trust-on-first-use certificate must never go anywhere else.
    static func isLocalHost(_ host: String) -> Bool {
        let host = host.lowercased()
        if host.hasSuffix(".local") || host.hasSuffix(".local.") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (parts[0], parts[1]) {
        case (10, _), (192, 168), (169, 254): return true
        case (172, let second): return (16...31).contains(second)
        default: return false
        }
    }
}
