import Foundation

/// A background worker (research, demo, figure, PDF reader) — GET /api/jobs.
public struct JobRecord: Sendable, Hashable, Codable, Identifiable {
	public var id: String
	/// research | demo | visual | pdf.
	public var kind: String
	public var chatId: String
	public var toolCallId: String
	/// running | done | error.
	public var status: String
	/// The live activity line while running.
	public var activity: String
	public var createdAt: String
	public var updatedAt: String
	public var error: String?

	public var isRunning: Bool { status == "running" }
}

public struct JobsSnapshot: Sendable, Hashable, Decodable {
	public var jobs: [JobRecord]
	/// A turn is running server-side for this chat.
	public var turnInFlight: Bool
}

extension APIClient {
	public func jobs(chatId: String) async throws -> JobsSnapshot {
		try await get("/api/jobs", query: [URLQueryItem(name: "chatId", value: chatId)], as: JobsSnapshot.self)
	}

	/// Stop a running background worker.
	public func abortJob(_ jobId: String) async throws {
		try await send(try json("POST", "/api/activity/abort", body: ["kind": "job", "id": jobId]))
	}

	/// Persist a demo/figure's colour inversion (the web's invert switch).
	public func setArtifactInverted(chatId: String, messageId: String, inverted: Bool) async throws {
		struct Input: Encodable { var messageId: String; var inverted: Bool }
		let path = "/api/chats/\(chatId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? chatId)/artifact-ui"
		try await send(try json("POST", path, body: ["input": Input(messageId: messageId, inverted: inverted)]))
	}
}

/// Where the transcript's phase dividers go — the web's rules
/// (src/core/phases.ts phaseAt3 + teachStepIndex) over the projected view.
public enum TranscriptPhases {
	/// Message index and part index for the "Teaching" divider: partIndex nil
	/// means before the whole message, otherwise at that step boundary.
	public struct Divider: Sendable, Equatable {
		public var messageIndex: Int
		public var partIndex: Int?
	}

	static func taggedNodeId(_ input: JSONValue?) -> Bool {
		guard let nodeId = input?["nodeId"]?.stringValue else { return false }
		return !nodeId.isEmpty
	}

	static func isTaggedTeachCall(_ part: NativeViewPart) -> Bool {
		(part.type == "tool-quiz" || part.type == "tool-explain") && taggedNodeId(part.input)
	}

	/// The single teach-seam divider, or nil before teaching starts.
	public static func teachDivider(in messages: [NativeViewMessage]) -> Divider? {
		var phase = "probe"
		for (index, message) in messages.enumerated() {
			let before = phase
			for part in message.parts {
				if phase == "probe", part.type == "tool-probe_done", part.state == "output-available",
					part.output?["ok"]?.boolValue != false {
					phase = "plan"
				}
				if phase == "plan", isTaggedTeachCall(part) { phase = "teach" }
			}
			if phase == "teach", before != "teach" {
				guard index > 0, message.role == .assistant else { return nil }
				return Divider(messageIndex: index, partIndex: teachStepIndex(message.parts))
			}
		}
		return nil
	}

	/// nil = before the message; otherwise the governing step-start's index.
	static func teachStepIndex(_ parts: [NativeViewPart]) -> Int? {
		var stepStarts = 0
		var latest: Int?
		for (index, part) in parts.enumerated() {
			if part.type == "step-start" {
				stepStarts += 1
				latest = index
				continue
			}
			if isTaggedTeachCall(part) { return stepStarts <= 1 ? nil : latest }
		}
		return nil
	}
}
