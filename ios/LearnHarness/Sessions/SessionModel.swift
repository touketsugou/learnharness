import Foundation
import LHAPI
import LHCache
import Observation

/// One open session: the server-projected view, the live turn stream, and
/// every learner action. Mirrors the web SessionModel's rules where they are
/// client-side (continuation after settle, 409 wait-and-retry, steering
/// queue); everything else comes projected from the server.
@MainActor
@Observable
final class SessionModel {
	struct QueuedSteer: Identifiable, Hashable {
		let id: String
		let text: String
	}

	/// Where text that failed to send goes back.
	private enum Unsent {
		case composer(String)
		case problem(String, text: String)
	}

	let chatId: String
	private let client: APIClient
	private let store: OfflineStore
	private let events: EventHub
	/// The unsent input, owned by AppModel so it outlives this page.
	let drafts: SessionDrafts

	private(set) var view: NativeSessionView?
	private(set) var offline = false
	/// A learner action is on its way (the Thinking… placeholder).
	private(set) var submitting = false
	/// Text sent but not yet visible in the transcript.
	private(set) var pendingText: String?
	/// A transient request/transport failure (provider failures come in the view).
	var requestError: String?
	private(set) var jobs: [JobRecord] = []
	private(set) var steerQueue: [QueuedSteer] = []
	/// The model picker's data (configured providers' models).
	private(set) var catalog: ModelCatalog?
	/// The stored settings a picker write returned, shown until the next view.
	private var writtenSettings: ChatSettings?

	private var streamTask: Task<Void, Never>?
	private var streaming = false
	private var listener: UUID?
	/// A failure must never be retried automatically (web parity).
	private var continuationBlocked = false
	private var steerSeq = 0

	init(chatId: String, client: APIClient, store: OfflineStore, events: EventHub, drafts: SessionDrafts) {
		self.chatId = chatId
		self.client = client
		self.store = store
		self.events = events
		self.drafts = drafts
	}

	// MARK: Derived

	var state: NativeSessionState? { view?.state }
	var isRunning: Bool { state?.status == .running }
	var isCompacting: Bool { state?.status == .compacting }
	/// Any learner input that starts a turn waits for this to be false.
	var canAct: Bool { !offline && !submitting && !isRunning && !isCompacting }

	/// What this session runs: its own record, each field falling back to
	/// the strong slot (a legacy unstamped session; resolveConversationSpec).
	var effectiveModel: ChatModelChoice? {
		(writtenSettings ?? state?.settings)?.model ?? catalog?.defaults?.model
	}

	var storedThinkingLevel: String? {
		(writtenSettings ?? state?.settings)?.thinkingLevel ?? catalog?.defaults?.thinkingLevel
	}

	var effectiveCatalogEntry: ModelCatalogEntry? {
		guard let model = effectiveModel else { return nil }
		return catalog?.models.first { $0.provider == model.provider && $0.id == model.id }
	}

	/// The stored level, or the one the engine resolves for an unset record.
	var effectiveThinkingLevel: String? {
		storedThinkingLevel ?? effectiveCatalogEntry.map { ThinkingLevels.defaultLevel($0.supportedLevels) }
	}

	var visibleSteers: [QueuedSteer] {
		let ids = Set(view?.messages.map(\.id) ?? [])
		return steerQueue.filter { !ids.contains($0.id) }
	}

	func job(forToolCall toolCallId: String?) -> JobRecord? {
		guard let toolCallId else { return nil }
		return jobs.first { $0.toolCallId == toolCallId }
	}

	// MARK: Lifecycle

	func start() {
		if listener == nil {
			listener = events.subscribe { [weak self] signal in self?.handle(signal) }
		}
		attach()
		Task { await refreshJobs() }
		Task { await refreshCatalog() }
	}

	func stop() {
		streamTask?.cancel()
		streamTask = nil
		if let listener { events.unsubscribe(listener) }
		listener = nil
	}

	/// Follow the session: snapshot → patches → settled (or one settled frame).
	func attach() {
		streamTask?.cancel()
		streamTask = Task { [weak self] in await self?.follow() }
	}

	private func follow() async {
		streaming = true
		defer { streaming = false }
		do {
			for try await frame in client.nativeStream(chatId) {
				guard !Task.isCancelled else { return }
				guard let next = NativeViewReducer.apply(frame, to: view) else {
					// A patch without a base: resynchronize from a fresh stream.
					attach()
					return
				}
				apply(next)
				if case .settled = frame {
					try? await store.saveView(next)
					await refreshJobs()
					await continueIfOwed()
				}
			}
		} catch is CancellationError {
		} catch APIError.transport {
			await fallBackToOffline()
		} catch let error as APIError {
			if case .streamEnded = error {
				// One read-only recovery: reattach the same server-owned turn.
				if !Task.isCancelled { try? await Task.sleep(for: .milliseconds(500)); attachIfIdleStream() }
			} else {
				requestError = error.message
			}
		} catch {
			requestError = error.localizedDescription
		}
	}

	private func attachIfIdleStream() {
		if !streaming { attach() }
	}

	private func apply(_ next: NativeSessionView) {
		view = next
		writtenSettings = nil
		offline = false
		submitting = false
		drafts.forgetResolved(dock: next.state.dock)
		if let pending = pendingText, next.messages.contains(where: { $0.role == .user && $0.parts.contains { $0.text == pending } }) {
			pendingText = nil
		}
	}

	private func fallBackToOffline() async {
		submitting = false
		if let cached = await store.loadView(chatId: chatId) {
			view = cached
			offline = true
		} else if view == nil {
			requestError = "The server can't be reached and this session has no offline copy."
		} else {
			offline = true
		}
	}

	private func handle(_ signal: EventHub.Signal) {
		switch signal {
		case .suspended:
			// The app is in the background; `.reconnected` reattaches.
			streamTask?.cancel()
			streamTask = nil
			streaming = false
		case .reconnected:
			if !streaming { attach() }
			Task { await refreshJobs() }
			Task { await refreshCatalog() }
		case .event(let event):
			guard event.chatId == chatId || event.type == "activity-changed" else { return }
			switch event.type {
			case "turn-started":
				attach()
			case "record-changed", "turn-settled", "compaction-changed":
				if !streaming { attach() }
			case "jobs-changed", "activity-changed":
				Task { await refreshJobs() }
			default:
				break
			}
		}
	}

	func refreshJobs() async {
		guard let snapshot = try? await client.jobs(chatId: chatId) else { return }
		jobs = snapshot.jobs
	}

	/// The record owes a reaction (e.g. a background result landed): run it,
	/// unless the session just failed (never an automatic retry).
	private func continueIfOwed() async {
		guard let state, state.needsContinuation, state.status == .idle, state.failure == nil,
			!continuationBlocked, !submitting else { return }
		await post(.continue)
	}

	// MARK: Turn-starting input

	/// POST an input event, waiting out a running turn like the web client
	/// (poll, then re-POST the same input), then follow the new turn.
	private func post(_ input: ChatInput, unsent: Unsent? = nil) async {
		if case .continue = input {} else { continuationBlocked = false }
		await submit(unsent: unsent) { client, chatId in try await client.sendInput(chatId: chatId, input) }
	}

	/// On failure, `unsent` goes back where it was typed.
	private func submit(unsent: Unsent? = nil, _ request: @escaping @Sendable (APIClient, String) async throws -> Void) async {
		guard !offline else {
			restore(unsent)
			return
		}
		submitting = true
		requestError = nil
		let deadline = ContinuousClock.now + .seconds(30)
		while true {
			do {
				try await request(client, chatId)
				attach()
				return
			} catch APIError.conflict(let message) {
				if ContinuousClock.now > deadline {
					fail("A turn is already running — try again in a moment. (\(message))", unsent: unsent)
					return
				}
				try? await Task.sleep(for: .milliseconds(500))
				if let snapshot = try? await client.jobs(chatId: chatId), snapshot.turnInFlight { continue }
			} catch APIError.refused(code: "models_not_configured", _) {
				fail("No model is set up on the server yet. Choose one in Settings, then send again.", unsent: unsent)
				return
			} catch {
				fail((error as? APIError)?.message ?? error.localizedDescription, unsent: unsent)
				return
			}
		}
	}

	private func fail(_ message: String, unsent: Unsent?) {
		submitting = false
		pendingText = nil
		requestError = message
		continuationBlocked = true
		restore(unsent)
	}

	/// Never an automatic retry: the text waits for the learner to send again.
	private func restore(_ unsent: Unsent?) {
		switch unsent {
		case .composer(let text):
			drafts.composer = SessionDrafts.restoring(text, into: drafts.composer)
		case .problem(let id, let text):
			drafts.problems[id] = SessionDrafts.restoring(text, into: drafts.problems[id] ?? "")
		case nil:
			break
		}
	}

	/// The composer: a plain message, or a steer while a turn runs.
	func sendText(_ raw: String) async {
		let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !text.isEmpty, !offline else { return }
		if isRunning {
			await steer(text)
			return
		}
		pendingText = text
		await post(.text(text), unsent: .composer(text))
	}

	private func steer(_ text: String) async {
		steerSeq += 1
		let id = "steer_c_\(Int(Date().timeIntervalSince1970 * 1000))_i\(steerSeq)"
		steerQueue.append(QueuedSteer(id: id, text: text))
		do {
			try await client.steer(chatId: chatId, steerId: id, text: text)
		} catch APIError.conflict {
			// The turn settled mid-send: send it as a plain message instead.
			steerQueue.removeAll { $0.id == id }
			pendingText = text
			await post(.text(text), unsent: .composer(text))
		} catch {
			steerQueue.removeAll { $0.id == id }
			requestError = (error as? APIError)?.message ?? error.localizedDescription
			restore(.composer(text))
		}
	}

	func answer(_ dock: NativeQuestionDock, request: AnswerRequest) async {
		var withReading = request
		if dock.needsReveal, let reading = drafts.readingThinking[dock.key]?.trimmingCharacters(in: .whitespacesAndNewlines), !reading.isEmpty {
			withReading.readingThinking = reading
		}
		let final = withReading
		let toolCallId = dock.toolCallId
		continuationBlocked = false
		await submit { client, chatId in try await client.answer(chatId: chatId, toolCallId: toolCallId, request: final) }
	}

	/// Skip the question silently (no turn; the next message wakes the agent).
	/// While a turn runs, the server parks the skip and the turn is stopped.
	func dismissQuestion(_ dock: NativeQuestionDock) async {
		let reading = dock.needsReveal ? drafts.readingThinking[dock.key] : nil
		do {
			try await client.dismissQuestion(chatId: chatId, toolCallId: dock.toolCallId, kind: dock.kind, questionText: dock.question, readingThinking: reading)
			if isRunning { try? await client.abortTurn(chatId: chatId) }
			attach()
		} catch {
			requestError = (error as? APIError)?.message ?? error.localizedDescription
		}
	}

	func submitThinking(problemCallId: String, text: String) async {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return }
		await post(.thinking(problemCallId: problemCallId, text: trimmed), unsent: .problem(problemCallId, text: text))
	}

	func discardProblem(_ problemCallId: String) async {
		do {
			try await client.dismissProblem(chatId: chatId, problemCallId: problemCallId)
			if isRunning { try? await client.abortTurn(chatId: chatId) }
			attach()
		} catch {
			requestError = (error as? APIError)?.message ?? error.localizedDescription
		}
	}

	func nextProblem() async { await post(.next) }

	func retryFailedTurn() async { await post(.retry) }

	func retryQuestion(_ malformed: NativeMalformedQuestion) async {
		await post(.retryQuestion(messageId: malformed.messageId, contentIndex: malformed.contentIndex, toolCallId: malformed.toolCallId))
	}

	func stopTurn() async {
		do { try await client.abortTurn(chatId: chatId) }
		catch { requestError = (error as? APIError)?.message ?? error.localizedDescription }
	}

	func stopJob(_ job: JobRecord) async {
		try? await client.abortJob(job.id)
		await refreshJobs()
	}

	func setInverted(messageId: String, inverted: Bool) async {
		try? await client.setArtifactInverted(chatId: chatId, messageId: messageId, inverted: inverted)
	}

	// MARK: Model and thinking level

	func refreshCatalog() async {
		if let fresh = try? await client.modelCatalog() { catalog = fresh }
	}

	/// A model pick keeps the stored level (clamped server-side) or populates
	/// the new model's default level — the web picker's rule.
	func pickModel(_ entry: ModelCatalogEntry) async {
		let level = ThinkingLevels.populate(storedThinkingLevel, supported: entry.supportedLevels)
		await writeSettings(ChatSettings(model: entry.choice, thinkingLevel: level))
	}

	func pickThinkingLevel(_ level: String) async {
		guard let model = effectiveModel else { return }
		await writeSettings(ChatSettings(model: model, thinkingLevel: level))
	}

	private func writeSettings(_ settings: ChatSettings) async {
		do {
			writtenSettings = try await client.updateChatSettings(chatId, settings)
		} catch {
			requestError = (error as? APIError)?.message ?? error.localizedDescription
		}
	}

	// MARK: Export and images

	/// A sendable loader for the share sheet (fetched only when shared).
	var markdownLoader: @Sendable () async throws -> String {
		let client = client
		let chatId = chatId
		return { try await client.markdown(chatId) }
	}

	func imageSnapshot(_ snapshotId: String) async -> ImageSnapshot? {
		if let cached = await store.loadImage(chatId: chatId, snapshotId: snapshotId),
			let image = try? JSONDecoder().decode(ImageSnapshot.self, from: cached) {
			return image
		}
		guard let image = try? await client.imageSnapshot(chatId: chatId, snapshotId: snapshotId) else { return nil }
		if let data = try? JSONEncoder().encode(image) { try? await store.saveImage(chatId: chatId, snapshotId: snapshotId, data: data) }
		return image
	}
}
