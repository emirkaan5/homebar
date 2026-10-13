import Foundation

/// A Sendable JSON tree. The SmartRent decoder uses it so that it can tolerate
/// fields that differ between hub and device models.
public enum JSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            // Encode whole numbers as integers so that IDs are sent as 42, not 42.0.
            if value.rounded() == value, abs(value) < 1e15 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let array) = self { return array }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let object) = self { return object }
        return nil
    }

    /// The string form of a scalar. Whole numbers print without a decimal point.
    public var stringValue: String? {
        switch self {
        case .string(let value): value
        case .number(let value):
            value.rounded() == value && abs(value) < 1e15 ? String(Int64(value)) : String(value)
        case .bool(let value): value ? "true" : "false"
        default: nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let value): value
        case .number(let value): value != 0
        case .string(let value): Bool(value.lowercased())
        default: nil
        }
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    public func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(self)
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
    }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}
