@preconcurrency import AVFoundation
import Foundation
import OSLog
import Speech

private let log = Logger(subsystem: "LearnHarness", category: "dictation")

/// On-device dictation (Speech framework, DictationTranscriber): live words —
/// finalized text plus the current volatile guess is reported as it changes.
@MainActor
final class AppleDictationEngine {
	private let mic = MicCapture()
	private var analyzer: SpeechAnalyzer?
	private var input: AsyncStream<AnalyzerInput>.Continuation?
	private var results: Task<String, any Error>?

	var meter: LevelMeter { mic.meter }

	/// The server's dictation language as an on-device locale: the matching
	/// supported locale, else (Multilingual, unsupported) the device language.
	static func locale(for language: String) async -> Locale? {
		if language != "multi", let match = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) {
			return match
		}
		return await DictationTranscriber.supportedLocale(equivalentTo: Locale.current)
	}

	/// Prepare the model (downloading it the first time), then listen.
	func start(language: String, onPreparingModel: @escaping @MainActor () -> Void, onTranscript: @escaping @MainActor (String) -> Void) async throws {
		guard let locale = await Self.locale(for: language) else {
			throw DictationError.message("On-device dictation isn’t available for this language.")
		}
		let transcriber = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
		let status = await AssetInventory.status(forModules: [transcriber])
		log.debug("speech assets \(String(describing: status), privacy: .public) for \(locale.identifier, privacy: .public)")
		guard status != .unsupported else {
			throw DictationError.message("On-device dictation isn’t available on this device.")
		}
		if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
			onPreparingModel()
			try await request.downloadAndInstall()
		}
		// No compatible format means the model can't run here (e.g. the
		// simulator lists the model as installed but has no recognizer).
		guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
			throw DictationError.message("On-device dictation isn’t available on this device.")
		}
		let micFormat = try mic.requireInput()
		log.debug("mic \(micFormat.description, privacy: .public) → analyzer \(format.description, privacy: .public) locale \(locale.identifier, privacy: .public)")
		guard let converter = BufferConverter(from: micFormat, to: format) else {
			throw DictationError.message("The microphone’s audio format isn’t supported.")
		}
		let analyzer = SpeechAnalyzer(modules: [transcriber])
		try await analyzer.prepareToAnalyze(in: format)
		self.analyzer = analyzer

		results = Task { @MainActor in
			var finalized = AttributedString()
			var volatile = AttributedString()
			for try await result in transcriber.results {
				if result.isFinal {
					finalized += result.text
					volatile = AttributedString()
				} else {
					volatile = result.text
				}
				onTranscript(Self.plain(finalized + volatile))
			}
			return Self.plain(finalized + volatile)
		}

		let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
		input = continuation
		try await analyzer.start(inputSequence: stream)
		try mic.start { buffer in
			if let converted = converter.convert(buffer) { continuation.yield(AnalyzerInput(buffer: converted)) }
		}
	}

	/// Stop listening and finalize: the complete transcript.
	func stop() async throws -> String {
		mic.stop()
		input?.finish()
		input = nil
		try await analyzer?.finalizeAndFinishThroughEndOfInput()
		analyzer = nil
		return try await results?.value ?? ""
	}

	func cancel() async {
		mic.stop()
		input?.finish()
		input = nil
		await analyzer?.cancelAndFinishNow()
		analyzer = nil
		results?.cancel()
	}

	private static func plain(_ text: AttributedString) -> String {
		String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
	}
}

enum DictationError: LocalizedError {
	case message(String)

	var errorDescription: String? {
		switch self {
		case .message(let text): text
		}
	}
}
