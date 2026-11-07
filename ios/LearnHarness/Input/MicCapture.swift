@preconcurrency import AVFoundation
import Synchronization

/// The microphone: an AVAudioEngine input tap feeding one consumer, with a
/// level meter. Nonisolated on purpose — the tap runs on the audio thread.
final class MicCapture: @unchecked Sendable {
	let meter = LevelMeter()
	private let engine = AVAudioEngine()
	private var running = false

	var inputFormat: AVAudioFormat { engine.inputNode.outputFormat(forBus: 0) }

	/// The input format, or a clear error when no microphone input exists
	/// (a zero sample rate: no input route).
	func requireInput() throws -> AVAudioFormat {
		let format = inputFormat
		guard format.sampleRate > 0, format.channelCount > 0 else {
			throw DictationError.message("No microphone input is available.")
		}
		return format
	}

	func start(_ consume: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
		let input = engine.inputNode
		let meter = meter
		input.installTap(onBus: 0, bufferSize: 2048, format: input.outputFormat(forBus: 0)) { buffer, _ in
			meter.record(buffer)
			consume(buffer)
		}
		engine.prepare()
		do {
			try engine.start()
			running = true
		} catch {
			input.removeTap(onBus: 0)
			throw error
		}
	}

	func stop() {
		guard running else { return }
		running = false
		engine.inputNode.removeTap(onBus: 0)
		engine.stop()
	}

	/// The record session for one dictation run (asynchronous activation:
	/// never blocks the main thread).
	static func activateSession() async throws {
		let session = AVAudioSession.sharedInstance()
		try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.duckOthers, .defaultToSpeaker])
		_ = try await session.activate(options: [])
	}

	static func deactivateSession() async {
		_ = try? await AVAudioSession.sharedInstance().deactivate(options: .notifyOthersOnDeactivation)
	}
}

/// Latest loudness, 0…1. Never resets between buffers (the web meter's rule:
/// a tick with no fresh audio repeats the last level instead of dropping).
final class LevelMeter: Sendable {
	private let value = Mutex<Float>(0)

	/// The web's dB window: −50 dB is silent, −10 dB is full.
	private static let floor: Float = -50
	private static let ceiling: Float = -10

	var level: Float { value.withLock { $0 } }

	func reset() { value.withLock { $0 = 0 } }

	func record(_ buffer: AVAudioPCMBuffer) {
		guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
		var sum: Float = 0
		for index in 0..<Int(buffer.frameLength) { sum += channel[index] * channel[index] }
		let rms = (sum / Float(buffer.frameLength)).squareRoot()
		let db = 20 * log10(max(rms, 1e-7))
		let level = min(max((db - Self.floor) / (Self.ceiling - Self.floor), 0), 1)
		value.withLock { $0 = level }
	}
}

/// Converts mic buffers to the format a recognizer wants (sample rate,
/// channel count, sample type). Used only on the audio thread.
final class BufferConverter: @unchecked Sendable {
	private let converter: AVAudioConverter?
	let target: AVAudioFormat

	init?(from source: AVAudioFormat, to target: AVAudioFormat) {
		self.target = target
		if source == target {
			converter = nil
		} else {
			guard let converter = AVAudioConverter(from: source, to: target) else { return nil }
			self.converter = converter
		}
	}

	func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
		guard let converter else { return buffer }
		let ratio = target.sampleRate / buffer.format.sampleRate
		let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
		guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
		var supplied = false
		var error: NSError?
		let status = converter.convert(to: output, error: &error) { _, inputStatus in
			if supplied {
				inputStatus.pointee = .noDataNow
				return nil
			}
			supplied = true
			inputStatus.pointee = .haveData
			return buffer
		}
		return status == .error || output.frameLength == 0 ? nil : output
	}
}
