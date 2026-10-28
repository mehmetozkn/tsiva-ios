import Foundation

/// A JSON-compatible value that can be attached to an event as a property.
///
/// `TsivaValue` conforms to the literal protocols, so properties can be written naturally:
///
/// ```swift
/// Tsiva.track("checkout_started", properties: [
///     "payment_method": "card",
///     "item_count": 3,
///     "total": 49.90,
///     "is_first_order": true
/// ])
/// ```
public enum TsivaValue: Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
}

extension TsivaValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension TsivaValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}

extension TsivaValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension TsivaValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension TsivaValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Bool must be checked before numbers: some decoders accept `true` as 1.
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value):
            // JSON has no representation for NaN or infinity.
            try container.encode(value.isFinite ? value : 0)
        case .bool(let value): try container.encode(value)
        }
    }
}
