import Foundation

private func encodePath(_ segment: String) -> String {
	segment.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? segment
}

extension APIClient {
	// MARK: Connection

	/// Verify the server address and token (GET /api/settings).
	public func verifyConnection() async throws {
		try await send(makeRequest("GET", "/api/settings"))
	}

	// MARK: Sessions

	public func listChats() async throws -> [ChatListItem] {
		try await get("/api/chats", as: ChatListResponse.self).chats
	}

	public func createChat(title: String, kind: ChatKind = .teach, graphContext: [GraphContextPick] = []) async throws -> CreatedChat {
		struct Body: Encodable {
			var title: String
			var kind: String?
			var graphContext: Context?
			struct Context: Encodable { var propositions: [GraphContextPick] }
		}
		let body = Body(title: title, kind: kind == .practice ? "practice" : nil,
						graphContext: graphContext.isEmpty ? nil : .init(propositions: graphContext))
		let (data, _) = try await send(try json("POST", "/api/chats", body: body))
		return try decode(CreatedChat.self, from: data)
	}

	public func renameChat(_ chatId: String, title: String) async throws {
		try await send(try json("PUT", "/api/chats/\(encodePath(chatId))", body: ["title": title]))
	}

	public func deleteChat(_ chatId: String, mode: ChatDeleteMode) async throws {
		try await send(makeRequest("DELETE", "/api/chats/\(encodePath(chatId))", query: [URLQueryItem(name: "mode", value: mode.rawValue)]))
	}

	/// Plain-text Markdown export of a session.
	public func markdown(_ chatId: String) async throws -> String {
		let (data, _) = try await send(makeRequest("GET", "/api/chats/\(encodePath(chatId))/markdown"))
		return String(decoding: data, as: UTF8.self)
	}

	/// A learner-image snapshot's bytes (PNG/JPEG).
	public func imageSnapshot(chatId: String, snapshotId: String) async throws -> Data {
		try await send(makeRequest("GET", "/api/chats/\(encodePath(chatId))/images/\(encodePath(snapshotId))")).0
	}

	// MARK: Native view

	public func nativeView(_ chatId: String) async throws -> NativeSessionView {
		try await get("/api/native/chats/\(encodePath(chatId))/view", as: NativeSessionView.self)
	}

	/// The turn-scoped view stream: snapshot → patch* → settled, then it ends.
	public func nativeStream(_ chatId: String) -> AsyncThrowingStream<NativeStreamFrame, any Error> {
		let events = events("/api/native/chats/\(encodePath(chatId))/stream")
		return AsyncThrowingStream { continuation in
			let task = Task {
				do {
					var sawTerminal = false
					for try await event in events {
						if event.data == "[DONE]" { sawTerminal = true; break }
						let frame = try JSONDecoder().decode(NativeStreamFrame.self, from: Data(event.data.utf8))
						continuation.yield(frame)
					}
					if sawTerminal { continuation.finish() } else { continuation.finish(throwing: APIError.streamEnded) }
				} catch let error as DecodingError {
					continuation.finish(throwing: APIError.decoding(String(describing: error)))
				} catch {
					continuation.finish(throwing: error)
				}
			}
			continuation.onTermination = { _ in task.cancel() }
		}
	}

	/// Submit a raw answer; the server grades it and starts the reaction turn.
	public func answer(chatId: String, toolCallId: String, request: AnswerRequest) async throws {
		struct Body: Encodable { var toolCallId: String; var request: AnswerRequest }
		try await send(try json("POST", "/api/native/chats/\(encodePath(chatId))/answer", body: Body(toolCallId: toolCallId, request: request)))
	}

	/// Skip the pending question (no turn starts; the next message wakes the agent).
	/// The record matches the web dismissal (dismissedAnswer) exactly.
	public func dismissQuestion(chatId: String, toolCallId: String, kind: String, questionText: String, readingThinking: String? = nil) async throws {
		struct Answer: Encodable {
			var kind: String
			var questionText: String
			var dontKnow = false
			var answers: [String] = []
			var dismissed = true
			var answeredAt: String
			var readingThinking: String?
		}
		struct Input: Encodable { var type = "dismiss"; var toolCallId: String; var answer: Answer }
		let reading = readingThinking?.trimmingCharacters(in: .whitespacesAndNewlines)
		let answer = Answer(kind: kind, questionText: questionText, answeredAt: ISO8601DateFormatter.lhFractional.string(from: Date()),
							readingThinking: reading?.isEmpty == false ? reading : nil)
		try await send(try json("POST", "/api/chats/\(encodePath(chatId))/dismiss", body: ["input": Input(toolCallId: toolCallId, answer: answer)]))
	}

	/// Discard the active practice problem.
	public func dismissProblem(chatId: String, problemCallId: String) async throws {
		struct Input: Encodable { var type = "dismiss-problem"; var problemCallId: String }
		try await send(try json("POST", "/api/chats/\(encodePath(chatId))/dismiss", body: ["input": Input(problemCallId: problemCallId)]))
	}

	// MARK: Turns

	/// POST /api/chat — starts a turn (acknowledged, then follow nativeStream).
	public func sendInput(chatId: String, _ input: ChatInput) async throws {
		struct Body: Encodable { var chatId: String; var input: ChatInput }
		try await send(try json("POST", "/api/chat", body: Body(chatId: chatId, input: input)))
	}

	/// Message for the RUNNING turn. 409 = no live turn (send as text instead).
	public func steer(chatId: String, steerId: String, text: String) async throws {
		struct Input: Encodable { var type = "steer"; var id: String; var text: String }
		try await send(try json("POST", "/api/chats/\(encodePath(chatId))/steer", body: ["input": Input(id: steerId, text: text)]))
	}

	/// Stop the running turn.
	public func abortTurn(chatId: String) async throws {
		try await send(try json("POST", "/api/activity/abort", body: ["kind": "turn", "id": chatId]))
	}

	// MARK: Files

	/// Upload learner files; returns their server paths in order.
	public func upload(_ files: [UploadFile]) async throws -> [UploadedFile] {
		let boundary = "lh-\(UUID().uuidString)"
		var body = Data()
		for file in files {
			let name = file.name.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
			body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"files\"; filename=\"\(name)\"\r\nContent-Type: \(file.mimeType)\r\n\r\n".utf8))
			body.append(file.data)
			body.append(Data("\r\n".utf8))
		}
		body.append(Data("--\(boundary)--\r\n".utf8))
		var request = makeRequest("POST", "/api/native/uploads", body: body, contentType: "multipart/form-data; boundary=\(boundary)")
		request.timeoutInterval = 300
		let (data, _) = try await send(request)
		return try decode(UploadResponse.self, from: data).files
	}

	// MARK: Notifications

	/// The window-level notification stream (GET /api/events): signals to refetch.
	public func serverEvents() -> AsyncThrowingStream<ServerEvent, any Error> {
		let events = events("/api/events", timeout: 120)
		return AsyncThrowingStream { continuation in
			let task = Task {
				do {
					for try await event in events {
						guard let type = event.event else { continue }
						let payload = (try? JSONDecoder().decode(JSONValue.self, from: Data(event.data.utf8))) ?? .null
						continuation.yield(ServerEvent(type: type, payload: payload))
					}
					continuation.finish()
				} catch {
					continuation.finish(throwing: error)
				}
			}
			continuation.onTermination = { _ in task.cancel() }
		}
	}
}

extension ISO8601DateFormatter {
	/// JavaScript's toISOString() shape.
	nonisolated(unsafe) static let lhFractional: ISO8601DateFormatter = {
		let formatter = ISO8601DateFormatter()
		formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		return formatter
	}()
}
