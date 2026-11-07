import Foundation

/// One server-sent event.
public struct SSEEvent: Sendable, Equatable {
	public var event: String?
	public var data: String

	public init(event: String? = nil, data: String) {
		self.event = event
		self.data = data
	}
}

/// Incremental text/event-stream parser (WHATWG rules for the fields the
/// server uses: `event`, `data`, comments). Feed bytes; complete events come
/// out at each blank line.
public struct SSEParser: Sendable {
	private var line: [UInt8] = []
	private var event: String?
	private var dataLines: [String] = []

	public init() {}

	public mutating func feed(_ byte: UInt8) -> SSEEvent? {
		guard byte == UInt8(ascii: "\n") else {
			line.append(byte)
			return nil
		}
		if line.last == UInt8(ascii: "\r") { line.removeLast() }
		let text = String(decoding: line, as: UTF8.self)
		line.removeAll(keepingCapacity: true)
		return process(text)
	}

	public mutating func feed<S: Sequence>(_ bytes: S) -> [SSEEvent] where S.Element == UInt8 {
		bytes.compactMap { feed($0) }
	}

	private mutating func process(_ text: String) -> SSEEvent? {
		if text.isEmpty {
			defer { event = nil; dataLines.removeAll() }
			guard !dataLines.isEmpty else { return nil }
			return SSEEvent(event: event, data: dataLines.joined(separator: "\n"))
		}
		if text.hasPrefix(":") { return nil }
		let field: Substring
		var value: Substring
		if let colon = text.firstIndex(of: ":") {
			field = text[..<colon]
			value = text[text.index(after: colon)...]
			if value.hasPrefix(" ") { value = value.dropFirst() }
		} else {
			field = Substring(text)
			value = ""
		}
		switch field {
		case "data": dataLines.append(String(value))
		case "event": event = String(value)
		default: break
		}
		return nil
	}
}
