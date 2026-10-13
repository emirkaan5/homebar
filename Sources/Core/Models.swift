import Foundation

public struct Home: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public enum DeviceKind: String, Sendable {
    case thermostat, lock, switchBinary, dimmer, light, leakSensor, motionSensor, unknown

    /// Devices that the Lights section shows.
    public var isLight: Bool { self == .light || self == .switchBinary || self == .dimmer }
}

public struct Device: Identifiable, Sendable, Equatable {
    public let id: String
    public var name: String
    public var kind: DeviceKind
    /// The type string from the service, kept for devices the app does not know.
    public var rawType: String
    public var attributes: [String: String]
    /// When each attribute last changed, if the service says so.
    public var attributeDates: [String: Date]
    public var isOnline: Bool
    public var batteryLevel: Int?

    public init(
        id: String, name: String, kind: DeviceKind, rawType: String, attributes: [String: String],
        attributeDates: [String: Date] = [:], isOnline: Bool = true, batteryLevel: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.rawType = rawType
        self.attributes = attributes
        self.attributeDates = attributeDates
        self.isOnline = isOnline
        self.batteryLevel = batteryLevel
    }

    public var thermostat: Thermostat? {
        kind == .thermostat ? Thermostat(attributes: attributes) : nil
    }

    public var doorLock: DoorLock? {
        kind == .lock ? DoorLock(attributes: attributes, dates: attributeDates) : nil
    }

    public var lightState: LightState? {
        kind.isLight ? LightState(attributes: attributes) : nil
    }
}

// MARK: - Thermostat

/// Attribute names that thermostats use on the SmartRent service.
public enum ThermostatAttribute {
    public static let currentTemp = "current_temp"
    public static let humidity = "current_humidity"
    public static let heatingSetpoint = "heating_setpoint"
    public static let coolingSetpoint = "cooling_setpoint"
    public static let mode = "mode"
    public static let fanMode = "fan_mode"
    public static let operatingState = "operating_state"
    public static let supportedModes = "supported_modes"
}

public enum ThermostatMode: String, CaseIterable, Sendable {
    case heat, cool, auto, off
    case auxHeat = "aux_heat"

    /// The modes the panel offers. Aux heat shows only when the thermostat reports it.
    public static let selectable: [ThermostatMode] = [.heat, .cool, .auto, .off]

    public var title: String {
        switch self {
        case .heat: "Heat"
        case .cool: "Cool"
        case .auto: "Auto"
        case .off: "Off"
        case .auxHeat: "Aux Heat"
        }
    }
}

public enum FanMode: String, CaseIterable, Sendable {
    case auto, on

    public var title: String { self == .auto ? "Auto" : "On" }
}

/// What the HVAC system does now, which can differ from the selected mode.
public enum OperatingState: Sendable, Equatable {
    case heating, cooling, fanOnly, idle, unknown

    public init(raw: String?) {
        let value = raw?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""
        if value.isEmpty || value == "none" {
            self = .unknown
        } else if value.contains("heat") {
            self = .heating
        } else if value.contains("cool") {
            self = .cooling
        } else if value.contains("fan") {
            self = .fanOnly
        } else {
            self = .idle
        }
    }
}

public enum SetpointKind: Sendable {
    case heating, cooling
}

public struct Thermostat: Sendable, Equatable {
    public var currentTemp: Int?
    public var humidity: Int?
    public var heatingSetpoint: Int?
    public var coolingSetpoint: Int?
    public var mode: ThermostatMode?
    public var fanMode: FanMode?
    public var operatingState: OperatingState
    /// The modes this thermostat accepts, in the order the panel shows them.
    public var supportedModes: [ThermostatMode]

    /// The smallest gap between the heating and cooling set points in auto mode.
    public static let minimumDeadband = 2

    public init(attributes: [String: String]) {
        currentTemp = Self.number(attributes[ThermostatAttribute.currentTemp])
        let humidity = Self.number(attributes[ThermostatAttribute.humidity])
        self.humidity = (humidity ?? 0) > 0 ? humidity : nil
        heatingSetpoint = Self.number(attributes[ThermostatAttribute.heatingSetpoint])
        coolingSetpoint = Self.number(attributes[ThermostatAttribute.coolingSetpoint])
        mode = attributes[ThermostatAttribute.mode].flatMap { ThermostatMode(rawValue: $0.lowercased()) }
        fanMode = attributes[ThermostatAttribute.fanMode].flatMap { FanMode(rawValue: $0.lowercased()) }
        operatingState = OperatingState(raw: attributes[ThermostatAttribute.operatingState])
        let reported = Set((attributes[ThermostatAttribute.supportedModes] ?? "")
            .split(separator: ",")
            .compactMap { ThermostatMode(rawValue: $0.trimmingCharacters(in: .whitespaces).lowercased()) })
        let order: [ThermostatMode] = [.heat, .cool, .auto, .auxHeat, .off]
        supportedModes = reported.isEmpty ? ThermostatMode.selectable : order.filter(reported.contains)
    }

    public func setpoint(_ kind: SetpointKind) -> Int? {
        kind == .heating ? heatingSetpoint : coolingSetpoint
    }

    /// The allowed set point range. Values under 40 mean that the thermostat uses °C.
    public var setpointRange: ClosedRange<Int> {
        let sample = heatingSetpoint ?? coolingSetpoint ?? currentTemp ?? 70
        return sample < 40 ? 10...32 : 50...90
    }

    /// Parses "70", "70.5", or "None". The service sends all values as strings.
    static func number(_ string: String?) -> Int? {
        guard let string, let value = Double(string.trimmingCharacters(in: .whitespaces)) else { return nil }
        return Int(value.rounded())
    }
}

// MARK: - Door lock

public enum LockAttribute {
    public static let locked = "locked"
    public static let notifications = "notifications"
}

public struct DoorLock: Sendable, Equatable {
    /// nil when the lock has not reported its state.
    public var isLocked: Bool?
    public var lastEvent: LockEvent?
    public var lastEventDate: Date?

    public init(attributes: [String: String], dates: [String: Date] = [:]) {
        isLocked = attributes[LockAttribute.locked].flatMap { Bool($0.lowercased()) }
        lastEvent = attributes[LockAttribute.notifications].flatMap(LockEvent.init(code:))
        lastEventDate = dates[LockAttribute.notifications]
    }
}

/// A Z-Wave lock alarm report, such as `ALARM_TYPE_19_LEVEL_3` (unlocked with keypad code 3).
/// The types are the ones that most Z-Wave locks share.
public struct LockEvent: Sendable, Equatable {
    public let type: Int
    public let level: Int

    public init?(code: String) {
        let parts = code.uppercased().split(separator: "_")
        guard parts.count == 5, parts[0] == "ALARM", parts[1] == "TYPE", parts[3] == "LEVEL",
              let type = Int(parts[2]), let level = Int(parts[4]) else { return nil }
        self.type = type
        self.level = level
    }

    public var description: String? {
        switch type {
        case 18: level > 0 ? "Locked with keypad code \(level)" : "Locked with keypad"
        case 19: level > 0 ? "Unlocked with keypad code \(level)" : "Unlocked with keypad"
        case 21: "Locked by hand"
        case 22: "Unlocked by hand"
        case 24: "Locked remotely"
        case 25: "Unlocked remotely"
        case 27: "Locked automatically"
        case 9, 17, 23: "The bolt is jammed"
        case 161: "Tamper alarm"
        case 167, 168, 169: "Battery is low"
        default: nil
        }
    }

    /// How the lock changed, short enough for one line: "With keypad code 42", "By hand".
    /// For a problem it is the full description.
    public var method: String? {
        switch type {
        case 18, 19: level > 0 ? "With keypad code \(level)" : "With keypad"
        case 21, 22: "By hand"
        case 24, 25: "From the app"
        case 27: "Automatically"
        default: description
        }
    }

    public var isProblem: Bool {
        [9, 17, 23, 161, 167, 168, 169].contains(type)
    }
}

// MARK: - Switches

public enum SwitchAttribute {
    public static let on = "on"
}

// MARK: - Lights

public enum LightAttribute {
    public static let on = SwitchAttribute.on
    /// 1…100. Missing when the light cannot dim.
    public static let brightness = "brightness"
    /// The colour temperature in mirek (1,000,000 / kelvin). Empty when the light shows a colour.
    public static let mirek = "mirek"
    public static let mirekMinimum = "mirek_min"
    public static let mirekMaximum = "mirek_max"
    /// A CIE xy colour as "x,y". Missing when the light has no colour.
    public static let color = "color"
}

public struct ColorXY: Sendable, Equatable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    init?(_ string: String?) {
        let parts = (string ?? "").split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2 else { return nil }
        self.init(x: parts[0], y: parts[1])
    }

    public var text: String { String(format: "%.4f,%.4f", x, y) }
}

public struct LightState: Sendable, Equatable {
    public var isOn: Bool
    public var brightness: Int?
    public var mirek: Int?
    public var mirekRange: ClosedRange<Int>?
    public var color: ColorXY?

    public var isDimmable: Bool { brightness != nil }
    public var supportsColor: Bool { color != nil }
    public var supportsTemperature: Bool { mirekRange != nil }
    /// True when the light shows a colour rather than a shade of white.
    public var showsColor: Bool { supportsColor && mirek == nil }

    public init(attributes: [String: String]) {
        isOn = attributes[LightAttribute.on] == "true"
        brightness = Thermostat.number(attributes[LightAttribute.brightness]).map { min(max($0, 0), 100) }
        mirek = Thermostat.number(attributes[LightAttribute.mirek])
        if let low = Thermostat.number(attributes[LightAttribute.mirekMinimum]),
           let high = Thermostat.number(attributes[LightAttribute.mirekMaximum]), low < high {
            mirekRange = low...high
        }
        color = ColorXY(attributes[LightAttribute.color])
    }
}

// MARK: - Commands and events

public struct AttributeChange: Sendable, Equatable {
    public let name: String
    public let value: String
}

public enum DeviceCommand: Sendable, Equatable {
    case setMode(ThermostatMode, device: Device.ID)
    case setFanMode(FanMode, device: Device.ID)
    case setHeatingSetpoint(Int, device: Device.ID)
    case setCoolingSetpoint(Int, device: Device.ID)
    case setLocked(Bool, device: Device.ID)
    case setOn(Bool, device: Device.ID)
    case setBrightness(Int, device: Device.ID)
    case setColorTemperature(mirek: Int, device: Device.ID)
    case setColor(ColorXY, device: Device.ID)

    public var deviceID: Device.ID {
        switch self {
        case .setMode(_, let id), .setFanMode(_, let id), .setHeatingSetpoint(_, let id),
             .setCoolingSetpoint(_, let id), .setLocked(_, let id), .setOn(_, let id),
             .setBrightness(_, let id), .setColorTemperature(_, let id), .setColor(_, let id): id
        }
    }

    public var change: AttributeChange {
        switch self {
        case .setMode(let mode, _): AttributeChange(name: ThermostatAttribute.mode, value: mode.rawValue)
        case .setFanMode(let fan, _): AttributeChange(name: ThermostatAttribute.fanMode, value: fan.rawValue)
        case .setHeatingSetpoint(let value, _): AttributeChange(name: ThermostatAttribute.heatingSetpoint, value: String(value))
        case .setCoolingSetpoint(let value, _): AttributeChange(name: ThermostatAttribute.coolingSetpoint, value: String(value))
        case .setLocked(let locked, _): AttributeChange(name: LockAttribute.locked, value: locked ? "true" : "false")
        case .setOn(let on, _): AttributeChange(name: SwitchAttribute.on, value: on ? "true" : "false")
        case .setBrightness(let level, _): AttributeChange(name: LightAttribute.brightness, value: String(level))
        case .setColorTemperature(let mirek, _): AttributeChange(name: LightAttribute.mirek, value: String(mirek))
        case .setColor(let color, _): AttributeChange(name: LightAttribute.color, value: color.text)
        }
    }

    /// How the store sends the command.
    public enum Timing: Sendable, Equatable {
        /// Send at once.
        case immediate
        /// Wait until the value stops changing, so that several clicks send one command.
        case debounce
        /// Send at once, then at most once per interval while the value keeps changing,
        /// so that a drag reaches the device continuously but at a rate it can take.
        case throttle(Duration)
    }

    public var timing: Timing {
        switch self {
        case .setHeatingSetpoint, .setCoolingSetpoint: .debounce
        case .setBrightness, .setColorTemperature: .throttle(.milliseconds(150))
        case .setMode, .setFanMode, .setLocked, .setOn, .setColor: .immediate
        }
    }

    /// A Z-Wave lock can take much longer than a thermostat to report back.
    public var confirmationTimeout: Duration? {
        if case .setLocked = self { return .seconds(30) }
        return nil
    }
}

public enum ConnectionState: Sendable, Equatable {
    case connecting, live, reconnecting, offline
}

public enum DeviceEvent: Sendable, Equatable {
    case attribute(device: Device.ID, name: String, value: String, date: Date? = nil)
    case connection(ConnectionState)
    case sessionExpired
}
