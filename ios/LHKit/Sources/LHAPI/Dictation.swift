import Foundation

/// Dictation and attachment helpers shared with the web client
/// (src/core/dictation.ts, components/dictation.tsx).
public enum DraftText {
	/// Append dictated text or quoted file paths to a draft (the web's
	/// joinDictation: trailing whitespace trimmed, one space between).
	public static func append(_ addition: String, to current: String) -> String {
		guard !addition.isEmpty else { return current }
		guard !current.isEmpty else { return addition }
		var trimmed = Substring(current)
		while let last = trimmed.last, last.isWhitespace { trimmed = trimmed.dropLast() }
		return trimmed.isEmpty ? addition : String(trimmed) + " " + addition
	}
}

public enum Deepgram {
	/// The streaming endpoint with the web's tuned parameters: nova-3,
	/// linear16 16 kHz mono, smart formatting, 300 ms endpointing, finals only.
	public static func listenURL(language: String) -> URL {
		var components = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
		components.queryItems = [
			URLQueryItem(name: "model", value: "nova-3"),
			URLQueryItem(name: "encoding", value: "linear16"),
			URLQueryItem(name: "sample_rate", value: "16000"),
			URLQueryItem(name: "channels", value: "1"),
			URLQueryItem(name: "smart_format", value: "true"),
			URLQueryItem(name: "punctuate", value: "true"),
			URLQueryItem(name: "endpointing", value: "300"),
			URLQueryItem(name: "language", value: language),
		]
		return components.url!
	}

	/// A final transcript from one streaming message, or nil.
	public static func finalTranscript(in message: Data) -> String? {
		guard let value = try? JSONDecoder().decode(JSONValue.self, from: message),
			value["type"]?.stringValue == "Results",
			value["is_final"]?.boolValue == true,
			let text = value["channel"]?["alternatives"]?[0]?["transcript"]?.stringValue,
			!text.isEmpty else { return nil }
		return text
	}
}

extension APIClient {
	/// The app-wide dictation language (GET /api/settings → dictation.language;
	/// the factory default is English).
	public func dictationLanguage() async throws -> String {
		struct Response: Decodable {
			struct Settings: Decodable {
				struct Dictation: Decodable { var language: String? }
				var dictation: Dictation?
			}
			var settings: Settings?
		}
		return try await get("/api/settings", as: Response.self).settings?.dictation?.language ?? "en"
	}

	/// A short-lived Deepgram token minted server-side (the key never leaves
	/// the server). 503 when no Deepgram key is configured.
	public func speechToken() async throws -> String {
		struct Response: Decodable { var token: String }
		return try await get("/api/stt/token", as: Response.self).token
	}
}
