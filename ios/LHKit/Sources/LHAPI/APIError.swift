import Foundation

/// Server and transport failures, mapped from status codes and the server's
/// JSON error envelopes ({error, code?}).
public enum APIError: Error, Sendable, Equatable {
	/// 401: missing or wrong access token.
	case unauthorized
	/// 404.
	case notFound(String)
	/// 409: a turn is already running (retry after it settles).
	case conflict(String)
	/// 503 refusals with a machine-readable code (e.g. models_not_configured).
	case refused(code: String?, message: String)
	/// 413: upload too large.
	case tooLarge(String)
	/// Any other non-2xx status.
	case http(status: Int, message: String)
	/// The request never got an HTTP response.
	case transport(String)
	/// The response did not match the expected shape.
	case decoding(String)
	/// A stream ended before its terminal frame.
	case streamEnded

	public var message: String {
		switch self {
		case .unauthorized: "The server rejected the access token."
		case .notFound(let message), .conflict(let message), .tooLarge(let message): message
		case .refused(_, let message): message
		case .http(_, let message): message
		case .transport(let message): message
		case .decoding(let message): "Unexpected server response: \(message)"
		case .streamEnded: "The connection dropped before the turn completed."
		}
	}

	/// Map a non-2xx response body to an error.
	static func from(status: Int, body: Data) -> APIError {
		let envelope = try? JSONDecoder().decode(JSONValue.self, from: body)
		let text = envelope?["error"]?.stringValue
			?? envelope?["message"]?.stringValue
			?? String(data: body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
		let message = (text?.isEmpty == false ? text! : HTTPURLResponse.localizedString(forStatusCode: status))
		switch status {
		case 401: return .unauthorized
		case 404: return .notFound(message)
		case 409: return .conflict(message)
		case 413: return .tooLarge(message)
		case 503: return .refused(code: envelope?["code"]?.stringValue, message: message)
		default: return .http(status: status, message: message)
		}
	}
}
