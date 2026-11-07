import Foundation

// Swift mirror of src/core/contracts/native.ts — the server-projected session
// view. Decoding is lenient where the server may grow (unknown enum values
// map to `.unknown`, part payloads stay JSON); tests decode
// tests/fixtures/native/*.json.

/// A string-backed enum that keeps unknown server values instead of failing.
public protocol LenientStringEnum: RawRepresentable, Codable, Sendable, Hashable where RawValue == String {
	static func unknown(_ raw: String) -> Self
}

extension LenientStringEnum {
	public init(from decoder: any Decoder) throws {
		let raw = try decoder.singleValueContainer().decode(String.self)
		self = Self(rawValue: raw) ?? .unknown(raw)
	}

	public func encode(to encoder: any Encoder) throws {
		var container = encoder.singleValueContainer()
		try container.encode(rawValue)
	}
}

public enum ChatKind: LenientStringEnum {
	case teach, practice, other(String)
	public init?(rawValue: String) {
		switch rawValue {
		case "teach": self = .teach
		case "practice": self = .practice
		default: self = .other(rawValue)
		}
	}
	public var rawValue: String {
		switch self {
		case .teach: "teach"
		case .practice: "practice"
		case .other(let raw): raw
		}
	}
	public static func unknown(_ raw: String) -> ChatKind { .other(raw) }
}

public enum SessionStatus: LenientStringEnum {
	case idle, running, compacting, other(String)
	public init?(rawValue: String) {
		switch rawValue {
		case "idle": self = .idle
		case "running": self = .running
		case "compacting": self = .compacting
		default: self = .other(rawValue)
		}
	}
	public var rawValue: String {
		switch self {
		case .idle: "idle"
		case .running: "running"
		case .compacting: "compacting"
		case .other(let raw): raw
		}
	}
	public static func unknown(_ raw: String) -> SessionStatus { .other(raw) }
}

public enum TeachingPhase: LenientStringEnum {
	case probe, plan, teach, other(String)
	public init?(rawValue: String) {
		switch rawValue {
		case "probe": self = .probe
		case "plan": self = .plan
		case "teach": self = .teach
		default: self = .other(rawValue)
		}
	}
	public var rawValue: String {
		switch self {
		case .probe: "probe"
		case .plan: "plan"
		case .teach: "teach"
		case .other(let raw): raw
		}
	}
	public static func unknown(_ raw: String) -> TeachingPhase { .other(raw) }
}

public enum QuestionMode: LenientStringEnum {
	case singleSelect, multiSelect, text, other(String)
	public init?(rawValue: String) {
		switch rawValue {
		case "single-select": self = .singleSelect
		case "multi-select": self = .multiSelect
		case "text": self = .text
		default: self = .other(rawValue)
		}
	}
	public var rawValue: String {
		switch self {
		case .singleSelect: "single-select"
		case .multiSelect: "multi-select"
		case .text: "text"
		case .other(let raw): raw
		}
	}
	public static func unknown(_ raw: String) -> QuestionMode { .other(raw) }
}

// MARK: - Transcript

/// One rendered part — the web renderer's part vocabulary, kept as JSON so
/// new part fields never break decoding.
public struct NativeViewPart: Sendable, Hashable, Codable {
	public var fields: [String: JSONValue]

	public init(fields: [String: JSONValue]) { self.fields = fields }

	public init(from decoder: any Decoder) throws {
		fields = try decoder.singleValueContainer().decode([String: JSONValue].self)
	}

	public func encode(to encoder: any Encoder) throws {
		var container = encoder.singleValueContainer()
		try container.encode(fields)
	}

	public var type: String { fields["type"]?.stringValue ?? "" }
	public var id: String? { fields["id"]?.stringValue }
	public var text: String? { fields["text"]?.stringValue }
	public var state: String? { fields["state"]?.stringValue }
	public var toolCallId: String? { fields["toolCallId"]?.stringValue }
	public var input: JSONValue? { fields["input"] }
	public var output: JSONValue? { fields["output"] }
	public var errorText: String? { fields["errorText"]?.stringValue }
	public var data: JSONValue? { fields["data"] }
	public subscript(key: String) -> JSONValue? { fields[key] }

	/// "quiz" for "tool-quiz"; nil for non-tool parts.
	public var toolName: String? { type.hasPrefix("tool-") ? String(type.dropFirst(5)) : nil }
}

public struct NativeViewMessage: Sendable, Hashable, Codable, Identifiable {
	public enum Role: String, Sendable, Hashable, Codable { case user, assistant }
	public var id: String
	public var role: Role
	public var parts: [NativeViewPart]
	public var metadata: JSONValue?

	public init(id: String, role: Role, parts: [NativeViewPart], metadata: JSONValue? = nil) {
		self.id = id
		self.role = role
		self.parts = parts
		self.metadata = metadata
	}
}

// MARK: - Docks

public struct QuizOption: Sendable, Hashable, Codable {
	public var label: String
	public var value: String
	public var description: String?

	public init(label: String, value: String, description: String? = nil) {
		self.label = label
		self.value = value
		self.description = description
	}
}

public struct NativeQuestionDock: Sendable, Hashable, Codable {
	public var toolCallId: String
	/// Draft/reset identity (differs from toolCallId only for legacy duplicate ids).
	public var key: String
	/// The posing tool: probe | recall | quiz | explain | ask_user_question.
	public var tool: String
	/// quiz | ask | explain.
	public var kind: String
	/// predict | check (teach-phase quizzes only).
	public var questionType: String?
	public var question: String
	public var context: String?
	public var mode: QuestionMode
	/// Display order (quiz options shuffled server-side, same as the web dock).
	public var options: [QuizOption]
	/// A teach-phase check waits behind the "Check your understanding" reveal.
	public var needsReveal: Bool
	public var confidenceStops: [Int]
	public var defaultConfidenceIndex: Int
}

public struct NativeProblemDock: Sendable, Hashable, Codable {
	public var toolCallId: String
	public var statement: String?
	public var mode: String?
}

public enum NativeDock: Sendable, Hashable, Codable {
	case question(NativeQuestionDock)
	case problem(NativeProblemDock)
	case betweenProblems
	case unknown(String)

	private enum CodingKeys: String, CodingKey { case type }

	public init(from decoder: any Decoder) throws {
		let type = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .type)
		switch type {
		case "question": self = .question(try NativeQuestionDock(from: decoder))
		case "problem": self = .problem(try NativeProblemDock(from: decoder))
		case "between-problems": self = .betweenProblems
		default: self = .unknown(type)
		}
	}

	public func encode(to encoder: any Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		switch self {
		case .question(let dock):
			try container.encode("question", forKey: .type)
			try dock.encode(to: encoder)
		case .problem(let dock):
			try container.encode("problem", forKey: .type)
			try dock.encode(to: encoder)
		case .betweenProblems:
			try container.encode("between-problems", forKey: .type)
		case .unknown(let type):
			try container.encode(type, forKey: .type)
		}
	}
}

public struct NativeMalformedQuestion: Sendable, Hashable, Codable {
	public var toolCallId: String
	public var messageId: String
	public var contentIndex: Int
	public var tool: String
}

// MARK: - Plan, failure, usage

public struct PlanNode: Sendable, Hashable, Codable, Identifiable {
	public var id: String
	public var title: String
	public var summary: String?
}

public struct PlanEdge: Sendable, Hashable, Codable {
	public var from: String
	public var to: String
}

public struct PlanTree: Sendable, Hashable, Codable {
	public var nodes: [PlanNode]
	public var edges: [PlanEdge]
	public var version: Int
}

public struct NativePlan: Sendable, Hashable, Codable {
	public var tree: PlanTree
	public var current: String?
	public var visited: [String]
}

public struct NativeFailure: Sendable, Hashable, Codable {
	public var message: String
	/// A failed response with retryable input (the Retry button).
	public var canRetry: Bool
}

public struct NativeUsage: Sendable, Hashable, Codable {
	public var contextTokens: Int?
	public var cost: Double
	public var unpriced: Double
	public var subscription: Double?
}

public struct NativeCoverage: Sendable, Hashable, Codable {
	public var totalMessages: Int
	public var coveredCount: Int
	public var uncoveredCount: Int
	public var coveredTokens: Int
	public var uncoveredTokens: Int
	public var running: Bool
	public var lastFoldedAt: String?
}

public struct ChatModelChoice: Sendable, Hashable, Codable {
	public var provider: String
	public var id: String
}

public struct ChatSettings: Sendable, Hashable, Codable {
	public var model: ChatModelChoice?
	public var thinkingLevel: String?
}

// MARK: - The view

/// Everything but the transcript — the `patch` frame's state block.
public struct NativeSessionState: Sendable, Hashable, Codable {
	public var version: Int
	public var chatId: String
	public var title: String
	public var kind: ChatKind
	public var createdAt: String
	public var updatedAt: String
	/// Monotonic within one stream; 0 for a standalone snapshot.
	public var revision: Int
	public var status: SessionStatus
	/// Teaching phase; nil for practice sessions.
	public var phase: TeachingPhase?
	/// What the running turn is doing right now ("Making a visual…").
	public var activity: String?
	public var dock: NativeDock?
	public var malformedQuestions: [NativeMalformedQuestion]
	public var plan: NativePlan?
	/// The record owes a reaction turn: an idle client sends `continue`.
	public var needsContinuation: Bool
	public var failure: NativeFailure?
	public var usage: NativeUsage
	public var settings: ChatSettings?
	public var coverage: NativeCoverage?
}

/// The server-projected session: state + transcript, flattened on the wire.
public struct NativeSessionView: Sendable, Hashable, Codable {
	public var state: NativeSessionState
	public var messages: [NativeViewMessage]

	public init(state: NativeSessionState, messages: [NativeViewMessage]) {
		self.state = state
		self.messages = messages
	}

	private enum CodingKeys: String, CodingKey { case messages }

	public init(from decoder: any Decoder) throws {
		state = try NativeSessionState(from: decoder)
		messages = try decoder.container(keyedBy: CodingKeys.self).decode([NativeViewMessage].self, forKey: .messages)
	}

	public func encode(to encoder: any Encoder) throws {
		try state.encode(to: encoder)
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(messages, forKey: .messages)
	}

	public var chatId: String { state.chatId }
}

public struct NativePatch: Sendable, Hashable, Codable {
	public var state: NativeSessionState
	/// The full ordered message id list.
	public var order: [String]
	/// Only messages whose content changed since the previous frame.
	public var messages: [NativeViewMessage]
}

/// GET /api/native/chats/:id/stream frames.
public enum NativeStreamFrame: Sendable, Hashable, Codable {
	case snapshot(NativeSessionView)
	case patch(NativePatch)
	case settled(NativeSessionView)

	private enum CodingKeys: String, CodingKey { case type, view }

	public init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		switch try container.decode(String.self, forKey: .type) {
		case "snapshot": self = .snapshot(try container.decode(NativeSessionView.self, forKey: .view))
		case "settled": self = .settled(try container.decode(NativeSessionView.self, forKey: .view))
		case "patch": self = .patch(try NativePatch(from: decoder))
		case let other:
			throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "unknown frame type \(other)")
		}
	}

	public func encode(to encoder: any Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		switch self {
		case .snapshot(let view):
			try container.encode("snapshot", forKey: .type)
			try container.encode(view, forKey: .view)
		case .settled(let view):
			try container.encode("settled", forKey: .type)
			try container.encode(view, forKey: .view)
		case .patch(let patch):
			try container.encode("patch", forKey: .type)
			try patch.encode(to: encoder)
		}
	}
}

/// Applies stream frames to a session view.
public enum NativeViewReducer {
	/// The new view, or nil when a patch arrives without a base (resync).
	public static func apply(_ frame: NativeStreamFrame, to view: NativeSessionView?) -> NativeSessionView? {
		switch frame {
		case .snapshot(let next), .settled(let next):
			return next
		case .patch(let patch):
			guard var current = view, current.chatId == patch.state.chatId else { return nil }
			var byId = Dictionary(current.messages.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
			for message in patch.messages { byId[message.id] = message }
			current.messages = patch.order.compactMap { byId[$0] }
			current.state = patch.state
			return current
		}
	}
}
