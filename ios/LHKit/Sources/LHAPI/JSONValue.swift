import Foundation

/// Any JSON value — the loose payloads of view parts (tool inputs/outputs,
/// marker data) that the server forwards verbatim from the record.
public enum JSONValue: Sendable, Hashable, Codable {
	case null
	case bool(Bool)
	case number(Double)
	case string(String)
	case array([JSONValue])
	case object([String: JSONValue])

	public init(from decoder: any Decoder) throws {
		let container = try decoder.singleValueContainer()
		if container.decodeNil() { self = .null }
		else if let value = try? container.decode(Bool.self) { self = .bool(value) }
		else if let value = try? container.decode(Double.self) { self = .number(value) }
		else if let value = try? container.decode(String.self) { self = .string(value) }
		else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
		else { self = .object(try container.decode([String: JSONValue].self)) }
	}

	public func encode(to encoder: any Encoder) throws {
		var container = encoder.singleValueContainer()
		switch self {
		case .null: try container.encodeNil()
		case .bool(let value): try container.encode(value)
		case .number(let value): try container.encode(value)
		case .string(let value): try container.encode(value)
		case .array(let value): try container.encode(value)
		case .object(let value): try container.encode(value)
		}
	}

	public var stringValue: String? { if case .string(let value) = self { value } else { nil } }
	public var doubleValue: Double? { if case .number(let value) = self { value } else { nil } }
	public var intValue: Int? { doubleValue.flatMap { $0.isFinite ? Int(exactly: $0.rounded()) : nil } }
	public var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }
	public var arrayValue: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
	public var objectValue: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
	public var isNull: Bool { self == .null }

	public subscript(key: String) -> JSONValue? { objectValue?[key] }
	public subscript(index: Int) -> JSONValue? {
		guard let array = arrayValue, array.indices.contains(index) else { return nil }
		return array[index]
	}

	/// Decode this value as a concrete model.
	public func decode<T: Decodable>(_ type: T.Type) throws -> T {
		try JSONDecoder().decode(T.self, from: JSONEncoder().encode(self))
	}
}
