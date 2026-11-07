@preconcurrency import AVFoundation
import Foundation
import LHAPI
import Observation

/// One dictation run at a time, app-wide (the web's single dictation per
/// window). The engine is a local preference: Apple on-device (default, live
/// words) or Deepgram (the web's engine, transcript inserted on stop).
@MainActor
@Observable
final class DictationController {
	enum Engine: String, CaseIterable {
		case apple
		case deepgram
	}

	enum Phase: Equatable {
		case idle
		/// Starting; the note says why it takes a while (model download).
		case preparing(String?)
		case recording
		case stopping
	}

	static let engineKey = "dictationEngine"
	static let meterCells = 32

	private(set) var phase: Phase = .idle
	private(set) var error: String?
	/// The mic button whose run failed; its field leaving clears the error.
	@ObservationIgnored private var errorSource: UUID?
	/// Rolling loudness history for the meter, sampled every 60 ms.
	private(set) var levels: [Float] = Array(repeating: 0, count: meterCells)
	/// The mic button whose field this run writes to.
	private(set) var targetID: UUID?

	@ObservationIgnored private let client: APIClient
	@ObservationIgnored private let defaults: UserDefaults
	@ObservationIgnored private var run = 0
	@ObservationIgnored private var base = ""
	@ObservationIgnored private var write: (@MainActor (String) -> Void)?
	@ObservationIgnored private var apple: AppleDictationEngine?
	@ObservationIgnored private var deepgram: DeepgramDictationEngine?
	@ObservationIgnored private var meterTask: Task<Void, Never>?
	@ObservationIgnored private var stopTask: Task<Void, Never>?
	@ObservationIgnored private var language: String?

	init(client: APIClient, defaults: UserDefaults = .standard) {
		self.client = client
		self.defaults = defaults
		Task { _ = await currentLanguage() }
	}

	var isActive: Bool { phase != .idle }

	var engine: Engine {
		get { Engine(rawValue: defaults.string(forKey: Self.engineKey) ?? "") ?? .apple }
		set { defaults.set(newValue.rawValue, forKey: Self.engineKey) }
	}

	func clearError() {
		error = nil
		errorSource = nil
	}

	func clearError(ifFrom target: UUID) {
		if errorSource == target { clearError() }
	}

	private func report(_ message: String?, from target: UUID?) {
		error = message
		errorSource = message == nil ? nil : target
	}

	/// Start listening into a field whose current text is `text`.
	func start(target: UUID, text: String, write: @escaping @MainActor (String) -> Void) {
		guard !isActive else { return }
		run += 1
		let run = run
		phase = .preparing(nil)
		clearError()
		targetID = target
		base = text
		self.write = write
		Task {
			do {
				guard await AVAudioApplication.requestRecordPermission() else {
					throw DictationError.message("Microphone access is off. Turn it on in Settings › Privacy & Security › Microphone.")
				}
				let language = await currentLanguage()
				guard run == self.run else { return }
				try await MicCapture.activateSession()
				let meter: LevelMeter
				switch engine {
				case .apple:
					let engine = AppleDictationEngine()
					apple = engine
					meter = engine.meter
					defer { if run != self.run { Task { await engine.cancel() } } }
					try await engine.start(
						language: language,
						onPreparingModel: { [weak self] in
							if self?.run == run { self?.phase = .preparing("Downloading the on-device speech model…") }
						},
						onTranscript: { [weak self] transcript in
							if self?.run == run { self?.apply(transcript) }
						}
					)
				case .deepgram:
					let engine = DeepgramDictationEngine(client: client)
					deepgram = engine
					meter = engine.meter
					defer { if run != self.run { engine.cancel() } }
					try await engine.start(language: language) { [weak self] message in
						guard let self, self.run == run else { return }
						self.stop(failure: message)
					}
				}
				guard run == self.run else { return }
				phase = .recording
				startMeter(meter)
			} catch {
				guard run == self.run else { return }
				await tearDown()
				report(error.localizedDescription, from: target)
			}
		}
	}

	/// End the run and keep the transcript.
	func stop(failure: String? = nil) {
		guard phase == .recording else {
			if case .preparing = phase { cancel() }
			return
		}
		phase = .stopping
		let run = run
		let target = targetID
		stopTask = Task {
			var transcript: String?
			var problem = failure
			if let apple {
				do { transcript = try await apple.stop() } catch { problem = problem ?? error.localizedDescription }
			}
			if let deepgram { transcript = await deepgram.stop() }
			guard run == self.run else { return }
			if let transcript { apply(transcript) }
			await tearDown()
			report(problem, from: target)
		}
	}

	/// Finish any live run before continuing (send/submit paths), so the
	/// whole transcript is in the field first.
	func finish() async {
		switch phase {
		case .recording: stop()
		case .preparing: cancel()
		case .idle, .stopping: break
		}
		await stopTask?.value
	}

	/// Drop the run (the field went away, or sign-out).
	func cancel() {
		guard isActive else { return }
		run += 1
		let apple = apple
		let deepgram = deepgram
		deepgram?.cancel()
		phase = .stopping
		write = nil
		Task {
			await apple?.cancel()
			await tearDown()
		}
	}

	func cancel(ifTarget target: UUID) {
		if targetID == target { cancel() }
	}

	private func apply(_ transcript: String) {
		write?(DraftText.append(transcript, to: base))
	}

	/// Release the audio session first, then go idle — so a new run can't
	/// start until the old one has let go of the session.
	private func tearDown() async {
		meterTask?.cancel()
		meterTask = nil
		apple = nil
		deepgram = nil
		write = nil
		await MicCapture.deactivateSession()
		targetID = nil
		phase = .idle
		levels = Array(repeating: 0, count: Self.meterCells)
	}

	private func startMeter(_ meter: LevelMeter) {
		meterTask = Task { [weak self] in
			while !Task.isCancelled {
				try? await Task.sleep(for: .milliseconds(60))
				guard let self else { return }
				var next = self.levels
				next.removeFirst()
				next.append(meter.level)
				self.levels = next
			}
		}
	}

	private func currentLanguage() async -> String {
		if let fresh = try? await client.dictationLanguage() { language = fresh }
		return language ?? "en"
	}
}
