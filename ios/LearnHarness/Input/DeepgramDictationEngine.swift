@preconcurrency import AVFoundation
import Foundation
import LHAPI

/// Cloud dictation (Deepgram streaming, the web's engine): audio goes from
/// the phone straight to Deepgram with a short-lived server-minted token;
/// finals are buffered and returned once, when the run stops.
@MainActor
final class DeepgramDictationEngine {
	/// The web's keyless line (DICTATION_KEYLESS).
	static let keyless = "Dictation needs a Deepgram key"

	private let client: APIClient
	private let mic = MicCapture()
	private var language = "en"
	private var socket: URLSessionWebSocketTask?
	private var receiver: Task<Void, Never>?
	private var sender: Task<Void, Never>?
	private var audio: AsyncStream<Data>.Continuation?
	private var finals: [String] = []
	private var stopping = false
	private var reconnects = 0
	private var onFailure: (@MainActor (String) -> Void)?

	var meter: LevelMeter { mic.meter }

	init(client: APIClient) {
		self.client = client
	}

	func start(language: String, onFailure: @escaping @MainActor (String) -> Void) async throws {
		self.language = language
		self.onFailure = onFailure
		let token = try await token()
		let micFormat = try mic.requireInput()
		guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
			let converter = BufferConverter(from: micFormat, to: target) else {
			throw DictationError.message("The microphone’s audio format isn’t supported.")
		}
		try await open(token: token)

		let (stream, continuation) = AsyncStream<Data>.makeStream()
		audio = continuation
		sender = Task { @MainActor [weak self] in
			for await frame in stream {
				try? await self?.socket?.send(.data(frame))
			}
		}
		try mic.start { buffer in
			guard let converted = converter.convert(buffer), let samples = converted.int16ChannelData?[0] else { return }
			continuation.yield(Data(bytes: samples, count: Int(converted.frameLength) * MemoryLayout<Int16>.size))
		}
	}

	/// Stop: mic first, flush queued audio, ask Deepgram to close (it sends
	/// its last finals first), with a 3 s safety net. Returns all finals.
	func stop() async -> String {
		stopping = true
		mic.stop()
		audio?.finish()
		audio = nil
		await sender?.value
		try? await socket?.send(.string(#"{"type":"CloseStream"}"#))
		let receiver = receiver
		let socket = socket
		await withTaskGroup(of: Void.self) { group in
			group.addTask { await receiver?.value }
			group.addTask { try? await Task.sleep(for: .seconds(3)) }
			await group.next()
			socket?.cancel(with: .normalClosure, reason: nil)
			group.cancelAll()
		}
		self.socket = nil
		return finals.joined(separator: " ")
	}

	func cancel() {
		stopping = true
		mic.stop()
		audio?.finish()
		audio = nil
		sender?.cancel()
		receiver?.cancel()
		socket?.cancel(with: .normalClosure, reason: nil)
		socket = nil
	}

	private func token() async throws -> String {
		do {
			return try await client.speechToken()
		} catch APIError.refused {
			throw DictationError.message(Self.keyless)
		} catch let error as APIError {
			throw DictationError.message(error.message)
		}
	}

	private func open(token: String) async throws {
		let task = URLSession.shared.webSocketTask(with: Deepgram.listenURL(language: language), protocols: ["bearer", token])
		socket = task
		task.resume()
		receiver = Task { @MainActor [weak self] in
			while true {
				do {
					let message = try await task.receive()
					let data: Data? = switch message {
					case .string(let text): Data(text.utf8)
					case .data(let bytes): bytes
					@unknown default: nil
					}
					if let data, let text = Deepgram.finalTranscript(in: data) { self?.finals.append(text) }
				} catch {
					await self?.lost(task)
					return
				}
			}
		}
	}

	/// An abnormal close mid-run: one reconnect with a fresh token, then give up.
	private func lost(_ task: URLSessionWebSocketTask) async {
		guard !stopping, task === socket else { return }
		guard reconnects < 1 else {
			onFailure?("Deepgram connection lost")
			return
		}
		reconnects += 1
		do {
			try await open(token: try await token())
		} catch {
			onFailure?("Deepgram reconnect failed")
		}
	}
}
