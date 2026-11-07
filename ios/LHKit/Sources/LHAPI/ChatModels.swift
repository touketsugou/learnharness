import Foundation

/// GET /api/chats row.
public struct ChatListItem: Sendable, Hashable, Codable, Identifiable {
	public var id: String
	public var title: String
	public var createdAt: String
	public var updatedAt: String
	public var kind: ChatKind
	public var messageCount: Int
	public var phase: TeachingPhase?
	public var pendingQuestion: Bool
	public var pendingProblem: Bool
	public var settings: ChatSettings?
	/// A teach turn is in flight.
	public var busy: Bool
	public var compacting: Bool
}

struct ChatListResponse: Decodable { var chats: [ChatListItem] }

/// POST /api/chats response.
public struct CreatedChat: Sendable, Hashable, Codable {
	public var id: String
	public var title: String
}

/// A proposition picked for a practice session's material.
public struct GraphContextPick: Sendable, Hashable, Codable {
	public var id: String
	public var name: String
	public var statement: String

	public init(id: String, name: String, statement: String) {
		self.id = id
		self.name = name
		self.statement = statement
	}
}

/// POST /api/chat input events (src/core/input-events.ts ChatInput). Answers
/// go through the native answer endpoint instead (server-side grading).
public enum ChatInput: Sendable, Hashable, Encodable {
	case text(String)
	case `continue`
	case retry
	case retryQuestion(messageId: String, contentIndex: Int, toolCallId: String)
	/// Practice: the learner's thinking on the active problem.
	case thinking(problemCallId: String, text: String)
	/// Practice: move on to the next problem.
	case next

	private enum CodingKeys: String, CodingKey { case type, text, messageId, contentIndex, toolCallId, problemCallId }

	public func encode(to encoder: any Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		switch self {
		case .text(let text):
			try container.encode("text", forKey: .type)
			try container.encode(text, forKey: .text)
		case .continue:
			try container.encode("continue", forKey: .type)
		case .retry:
			try container.encode("retry", forKey: .type)
		case .retryQuestion(let messageId, let contentIndex, let toolCallId):
			try container.encode("retry-question", forKey: .type)
			try container.encode(messageId, forKey: .messageId)
			try container.encode(contentIndex, forKey: .contentIndex)
			try container.encode(toolCallId, forKey: .toolCallId)
		case .thinking(let problemCallId, let text):
			try container.encode("thinking", forKey: .type)
			try container.encode(problemCallId, forKey: .problemCallId)
			try container.encode(text, forKey: .text)
		case .next:
			try container.encode("next", forKey: .type)
		}
	}
}

/// The learner's raw answer (server grades it): src/core/question-core.ts AnswerRequest.
public struct AnswerRequest: Sendable, Hashable, Codable {
	public var dontKnow: Bool?
	/// Selected option `value`s.
	public var values: [String]?
	/// ask: "Other" free text.
	public var other: String?
	/// Text-mode answer.
	public var text: String?
	/// The learner's reasoning on the question (select modes).
	public var thinking: String?
	/// Thinking while reading the teaching (rides teach-phase check answers).
	public var readingThinking: String?
	/// quiz: stated probability (0–100) that the selection is correct.
	public var confidence: Int?

	public init(dontKnow: Bool? = nil, values: [String]? = nil, other: String? = nil, text: String? = nil,
				thinking: String? = nil, readingThinking: String? = nil, confidence: Int? = nil) {
		self.dontKnow = dontKnow
		self.values = values
		self.other = other
		self.text = text
		self.thinking = thinking
		self.readingThinking = readingThinking
		self.confidence = confidence
	}
}

/// POST /api/native/uploads result entry.
public struct UploadedFile: Sendable, Hashable, Codable {
	public var name: String
	/// Server path to quote into the message (see FilePathQuoting).
	public var path: String
	public var bytes: Int
}

struct UploadResponse: Decodable { var files: [UploadedFile] }

/// A file to upload.
public struct UploadFile: Sendable, Hashable {
	public var name: String
	public var mimeType: String
	public var data: Data

	public init(name: String, mimeType: String, data: Data) {
		self.name = name
		self.mimeType = mimeType
		self.data = data
	}
}

/// GET /api/events notification (src/core/events.ts): a signal to refetch.
public struct ServerEvent: Sendable, Hashable {
	public var type: String
	public var payload: JSONValue

	public var chatId: String? { payload["chatId"]?.stringValue }
}

/// Chat deletion: keep the knowledge it contributed, or delete it too.
public enum ChatDeleteMode: String, Sendable {
	case preserveGraph = "preserve-graph"
	case deleteNodes = "delete-nodes"
}

/// Quote a server path the way desktop attachments are written into messages
/// (src/core/file-paths.ts quoteFilePath): a backtick run one longer than any
/// run inside, padded when the path itself starts or ends with a backtick.
public enum FilePathQuoting {
	public static func quote(_ path: String) -> String {
		var width = 1
		var run = 0
		for character in path {
			if character == "`" { run += 1; width = max(width, run + 1) } else { run = 0 }
		}
		let delimiter = String(repeating: "`", count: width)
		let padding = path.hasPrefix("`") || path.hasSuffix("`") ? " " : ""
		return delimiter + padding + path + padding + delimiter
	}
}
