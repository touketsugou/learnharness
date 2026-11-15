import Foundation
import LHAPI
import LHCache
import Testing
@testable import LearnHarness

/// The fixtures the server's own projection produced (tests/fixtures/native).
private enum Fixture {
	static let directory = URL(fileURLWithPath: #filePath)
		.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
		.appending(path: "tests/fixtures/native")

	static func data(_ name: String) -> Data { try! Data(contentsOf: directory.appending(path: name)) }

	/// The pending-quiz session: a learner message, then a quiz waiting.
	static var view: NativeSessionView { try! JSONDecoder().decode(NativeSessionView.self, from: data("pending-quiz.view.json")) }
	static let chatId = "chat_native_fixture"
	static let streamPath = "/api/native/chats/\(chatId)/stream"
}

/// One session model on a fake server, with its own offline store.
@MainActor
private struct Harness {
	let server = FakeServer()
	let store: OfflineStore
	let drafts = SessionDrafts()
	let model: SessionModel

	init() {
		let root = FileManager.default.temporaryDirectory.appending(path: "lh-session-tests-\(UUID().uuidString)")
		store = OfflineStore(root: root.appending(path: "data"), imageRoot: root.appending(path: "images"))
		model = SessionModel(chatId: Fixture.chatId, client: server.client(), store: store, events: EventHub(), drafts: drafts)
	}

	/// The session idle with nothing pending (the quiz answered and gone).
	static func idle(needsContinuation: Bool = false, failure: String? = nil) -> NativeSessionView {
		var view = Fixture.view
		view.state.status = .idle
		view.state.dock = nil
		view.state.needsContinuation = needsContinuation
		view.state.failure = failure.map { try! JSONValue.object(["message": .string($0), "canRetry": .bool(true)]).decode(NativeFailure.self) }
		return view
	}

	static func running() -> NativeSessionView {
		var view = idle()
		view.state.status = .running
		return view
	}

	/// `view` with a learner message appended.
	static func echoing(_ text: String, in view: NativeSessionView) -> NativeSessionView {
		var view = view
		view.messages.append(NativeViewMessage(id: "msg_echo", role: .user, parts: [NativeViewPart(fields: ["type": .string("text"), "text": .string(text)])]))
		return view
	}

	/// Start following `view`, and wait until it shows.
	func open(_ view: NativeSessionView) async throws {
		server.on("GET", Fixture.streamPath, .stream([.settled(view)]))
		model.start()
		try await until { model.view == view && !model.submitting }
	}

	var chatPosts: [JSONValue] { server.requests("POST", "/api/chat").compactMap { $0.json?["input"] } }
	var streamRequests: Int { server.requests("GET", Fixture.streamPath).count }
}

private struct TimedOut: Error {}

/// Wait for something the model does on its own tasks.
@MainActor
private func until(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
	let deadline = ContinuousClock.now + timeout
	while !condition() {
		guard ContinuousClock.now < deadline else { throw TimedOut() }
		try await Task.sleep(for: .milliseconds(10))
	}
}

/// Give the model's own tasks time to do what they would (for "it doesn't").
private func settle() async throws { try await Task.sleep(for: .milliseconds(300)) }

@MainActor
@Suite("Session model: sending")
struct SessionModelSendingTests {
	@Test func aMessageWhileIdleIsPostedAndShownUntilTheServerHasIt() async throws {
		let h = Harness()
		try await h.open(Harness.idle())
		h.server.on("POST", "/api/chat", .ok)
		// The server's view doesn't have the message yet: it stays shown as pending.
		h.server.on("GET", Fixture.streamPath, .stream([.settled(Harness.idle())]))
		await h.model.sendText("  hello  ")
		#expect(h.chatPosts == [.object(["type": .string("text"), "text": .string("hello")])])
		try await until { h.streamRequests == 2 && !h.model.submitting }
		#expect(h.model.pendingText == "hello")

		h.server.on("GET", Fixture.streamPath, .stream([.settled(Harness.echoing("hello", in: Harness.idle()))]))
		h.model.attach()
		try await until { h.model.pendingText == nil }
		#expect(h.model.requestError == nil)
	}

	@Test func aMessageWhileATurnRunsIsSteered() async throws {
		let h = Harness()
		try await h.open(Harness.running())
		h.server.on("POST", "/api/chats/\(Fixture.chatId)/steer", .ok)
		await h.model.sendText("also this")
		let steers = h.server.requests("POST", "/api/chats/\(Fixture.chatId)/steer")
		#expect(steers.count == 1)
		#expect(steers.first?.json?["input"]?["text"] == .string("also this"))
		#expect(h.model.visibleSteers.map(\.text) == ["also this"])
		#expect(h.chatPosts.isEmpty)
	}

	@Test func aSteerTheSettledTurnRefusesIsSentAsAMessage() async throws {
		let h = Harness()
		try await h.open(Harness.running())
		h.server.on("POST", "/api/chats/\(Fixture.chatId)/steer", .error(409, "No turn is running"))
		h.server.on("POST", "/api/chat", .ok)
		await h.model.sendText("also this")
		#expect(h.model.steerQueue.isEmpty)
		#expect(h.chatPosts == [.object(["type": .string("text"), "text": .string("also this")])])
		#expect(h.model.requestError == nil)
	}

	@Test func aFailedSteerGoesBackToTheComposer() async throws {
		let h = Harness()
		try await h.open(Harness.running())
		h.server.on("POST", "/api/chats/\(Fixture.chatId)/steer", .error(500, "boom"))
		await h.model.sendText("also this")
		#expect(h.model.steerQueue.isEmpty)
		#expect(h.model.requestError == "boom")
		#expect(h.drafts.composer == "also this")
	}

	@Test func noModelSaysSoAndGivesTheTextBack() async throws {
		let h = Harness()
		try await h.open(Harness.idle())
		h.server.on("POST", "/api/chat", .error(503, "No model configured", code: "models_not_configured"))
		await h.model.sendText("hello")
		#expect(h.model.requestError == "No model is set up on the server yet. Choose one in Settings, then send again.")
		#expect(h.drafts.composer == "hello")
		#expect(h.model.pendingText == nil)
		#expect(!h.model.submitting)
	}

	@Test func aBusyServerIsWaitedOutAndTheSameInputSentAgain() async throws {
		let h = Harness()
		try await h.open(Harness.idle())
		h.server.on("POST", "/api/chat", .error(409, "A turn is already running"), .ok)
		await h.model.sendText("hello")
		let text: JSONValue = .object(["type": .string("text"), "text": .string("hello")])
		#expect(h.chatPosts == [text, text])
		#expect(h.model.requestError == nil)
		#expect(h.drafts.composer.isEmpty)
	}

	@Test func aServerBusyPastTheWaitGivesUpAndGivesTheTextBack() async throws {
		let h = Harness()
		try await h.open(Harness.idle())
		h.model.conflictWait = .milliseconds(200)
		h.server.on("POST", "/api/chat", .error(409, "A turn is already running"))
		await h.model.sendText("hello")
		#expect(h.model.requestError?.hasPrefix("A turn is already running — try again in a moment.") == true)
		#expect(h.drafts.composer == "hello")
		#expect(h.chatPosts.count >= 2)
	}

	@Test func aNetworkFailureGivesTheTextBackInFrontOfNewTyping() async throws {
		let h = Harness()
		try await h.open(Harness.idle())
		h.server.on("POST", "/api/chat", .unreachable)
		// The composer let go of "hello"; the learner typed on meanwhile.
		h.drafts.composer = "typed since"
		await h.model.sendText("hello")
		#expect(h.model.requestError != nil)
		#expect(h.drafts.composer == "hello\n\ntyped since")
	}

	@Test func aFailedPracticeAnswerGoesBackToItsProblem() async throws {
		let h = Harness()
		try await h.open(Harness.idle())
		h.server.on("POST", "/api/chat", .error(500, "boom"))
		await h.model.submitThinking(problemCallId: "p1", text: "my working")
		#expect(h.chatPosts.first?["type"] == .string("thinking"))
		#expect(h.drafts.problems["p1"] == "my working")
	}

	@Test func sendingOfflineSendsNothingAndGivesTheTextBack() async throws {
		let h = Harness()
		h.server.on("GET", Fixture.streamPath, .unreachable)
		try await h.store.saveView(Harness.idle())
		h.model.start()
		try await until { h.model.offline }
		await h.model.sendText("hello")
		#expect(h.chatPosts.isEmpty)
		#expect(h.drafts.composer == "hello")
	}

	@Test func anAnswerAfterReadingCarriesTheReadingThinking() async throws {
		let h = Harness()
		var view = Fixture.view
		guard case .question(var dock) = view.state.dock else { Issue.record("The fixture has no question"); return }
		dock.needsReveal = true
		view.state.dock = .question(dock)
		try await h.open(view)
		h.drafts.readingThinking[dock.key] = "  Mercury, I think  "
		h.server.on("POST", "/api/native/chats/\(Fixture.chatId)/answer", .ok)
		await h.model.answer(dock, request: AnswerRequest(values: ["Mercury"], confidence: 70))
		let body = h.server.requests("POST", "/api/native/chats/\(Fixture.chatId)/answer").first?.json
		#expect(body?["toolCallId"] == .string(dock.toolCallId))
		#expect(body?["request"]?["readingThinking"] == .string("Mercury, I think"))
		#expect(body?["request"]?["values"] == .array([.string("Mercury")]))
	}
}

@MainActor
@Suite("Session model: continuation")
struct SessionModelContinuationTests {
	@Test func aSettledRecordThatOwesAReactionContinues() async throws {
		let h = Harness()
		h.server.on("GET", Fixture.streamPath, .stream([.settled(Harness.idle(needsContinuation: true))]), .stream([.settled(Harness.idle())]))
		h.server.on("POST", "/api/chat", .ok)
		h.model.start()
		try await until { !h.chatPosts.isEmpty }
		#expect(h.chatPosts == [.object(["type": .string("continue")])])
	}

	@Test func aFailedSendIsNeverFollowedByAnAutomaticContinue() async throws {
		let h = Harness()
		try await h.open(Harness.idle())
		h.server.on("POST", "/api/chat", .error(500, "boom"))
		await h.model.sendText("hello")
		#expect(h.chatPosts.count == 1)
		h.server.on("GET", Fixture.streamPath, .stream([.settled(Harness.idle(needsContinuation: true))]))
		h.model.attach()
		try await until { h.model.state?.needsContinuation == true }
		try await settle()
		#expect(h.chatPosts.count == 1)
	}

	@Test func aFailedTurnIsNeverContinuedAutomatically() async throws {
		let h = Harness()
		h.server.on("POST", "/api/chat", .ok)
		try await h.open(Harness.idle(needsContinuation: true, failure: "The provider failed"))
		try await settle()
		#expect(h.chatPosts.isEmpty)
	}
}

@MainActor
@Suite("Session model: stream")
struct SessionModelStreamTests {
	@Test func framesApplyInOrderAndTheSettledViewIsKeptOffline() async throws {
		let h = Harness()
		let frames = try JSONDecoder().decode([NativeStreamFrame].self, from: Fixture.data("stream-frames.json"))
		guard case .settled(let settled) = frames.last else { Issue.record("The fixture doesn't end settled"); return }
		h.server.on("GET", Fixture.streamPath, .stream(frames))
		h.model.start()
		try await until { h.model.view == settled }
		let deadline = ContinuousClock.now + .seconds(5)
		while await h.store.loadView(chatId: Fixture.chatId) != settled {
			guard ContinuousClock.now < deadline else { throw TimedOut() }
			try await Task.sleep(for: .milliseconds(10))
		}
	}

	@Test func aPatchWithoutABaseResynchronizes() async throws {
		let h = Harness()
		let frames = try JSONDecoder().decode([NativeStreamFrame].self, from: Fixture.data("stream-frames.json"))
		guard case .patch = frames[1], case .settled(let settled) = frames[2] else { Issue.record("Unexpected fixture"); return }
		h.server.on("GET", Fixture.streamPath, .stream([frames[1]]), .stream([.settled(settled)]))
		h.model.start()
		try await until { h.model.view == settled }
		#expect(h.streamRequests == 2)
		#expect(h.model.requestError == nil)
	}

	@Test func unreachableFallsBackToTheOfflineCopy() async throws {
		let h = Harness()
		let saved = Harness.idle()
		try await h.store.saveView(saved)
		h.server.on("GET", Fixture.streamPath, .unreachable)
		h.model.start()
		try await until { h.model.offline }
		#expect(h.model.view == saved)
		#expect(!h.model.canAct)
	}

	@Test func unreachableWithoutAnOfflineCopySaysSo() async throws {
		let h = Harness()
		h.server.on("GET", Fixture.streamPath, .unreachable)
		h.model.start()
		try await until { h.model.requestError != nil }
		#expect(h.model.requestError == "The server can't be reached and this session has no offline copy.")
		#expect(h.model.view == nil)
	}

	@Test func startingAgainAfterStopFollowsTheSessionAgain() async throws {
		let h = Harness()
		try await h.open(Harness.idle())
		h.model.stop()
		let later = Harness.echoing("from the browser", in: Harness.idle())
		h.server.on("GET", Fixture.streamPath, .stream([.settled(later)]))
		h.model.start()
		try await until { h.model.view == later }
		#expect(h.streamRequests == 2)
	}

	@Test func aNewViewForgetsTheDraftsOfResolvedQuestions() async throws {
		let h = Harness()
		h.drafts.questions["old"] = QuestionFormDraft(confidenceIndex: 0)
		h.drafts.questions["call-1"] = QuestionFormDraft(confidenceIndex: 2)
		try await h.open(Fixture.view)
		#expect(Set(h.drafts.questions.keys) == ["call-1"])
	}
}

@MainActor
@Suite("Session model: card actions")
struct SessionModelCardActionTests {
	private func job() throws -> JobRecord {
		try JSONDecoder().decode(JobRecord.self, from: Data("""
		{"id":"job-1","kind":"research","chatId":"\(Fixture.chatId)","toolCallId":"call-9","status":"running","activity":"","createdAt":"2026-11-07T00:00:00.000Z","updatedAt":"2026-11-07T00:00:00.000Z"}
		""".utf8))
	}

	@Test func stoppingAJobReportsAFailure() async throws {
		let h = Harness()
		h.server.on("POST", "/api/activity/abort", .error(500, "boom"), .ok)
		#expect(await h.model.stopJob(try job()) == "Couldn't stop: boom")
		#expect(await h.model.stopJob(try job()) == nil)
		#expect(h.server.requests("POST", "/api/activity/abort").first?.json == .object(["kind": .string("job"), "id": .string("job-1")]))
	}

	@Test func savingTheColourSettingReportsAFailure() async throws {
		let h = Harness()
		h.server.on("POST", "/api/chats/\(Fixture.chatId)/artifact-ui", .error(500, "boom"), .ok)
		#expect(await h.model.setInverted(messageId: "m1", inverted: true) == "Couldn't save the colour setting: boom")
		#expect(await h.model.setInverted(messageId: "m1", inverted: true) == nil)
	}
}

@MainActor
@Suite("Session model: turn cue")
struct SessionModelTurnCueTests {
	/// Follow the session again and wait until `view` shows.
	private func follow(_ h: Harness, to view: NativeSessionView) async throws {
		h.server.on("GET", Fixture.streamPath, .stream([.settled(view)]))
		h.model.attach()
		try await until { h.model.view == view }
	}

	@Test func aTurnThatStopsRunningCues() async throws {
		let h = Harness()
		try await h.open(Harness.running())
		try await follow(h, to: Harness.idle())
		#expect(h.model.turnCue == 1)
	}

	@Test func aNewQuestionCues() async throws {
		let h = Harness()
		try await h.open(Harness.idle())
		try await follow(h, to: Fixture.view)
		#expect(h.model.turnCue == 1)
		// The same question again is no news.
		var same = Fixture.view
		same.state.revision += 1
		try await follow(h, to: same)
		#expect(h.model.turnCue == 1)
	}

	@Test func aTurnEndingOnAQuestionCuesOnce() async throws {
		let h = Harness()
		try await h.open(Harness.running())
		try await follow(h, to: Fixture.view)
		#expect(h.model.turnCue == 1)
	}

	@Test func theFirstViewAfterOpeningOrComingBackDoesNotCue() async throws {
		let h = Harness()
		try await h.open(Fixture.view)
		#expect(h.model.turnCue == 0)
		try await follow(h, to: Harness.running())
		h.model.stop()
		// Back from another tab: the turn ended meanwhile.
		let later = Harness.idle()
		h.server.on("GET", Fixture.streamPath, .stream([.settled(later)]))
		h.model.start()
		try await until { h.model.view == later }
		#expect(h.model.turnCue == 0)
	}
}
