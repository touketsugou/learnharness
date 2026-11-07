import Foundation

/// One cloud server: its base URL and the access token (LH_REMOTE_TOKEN).
public struct ServerConnection: Sendable, Hashable {
	public let baseURL: URL
	public let token: String

	public init(baseURL: URL, token: String) {
		self.baseURL = baseURL
		self.token = token
	}

	/// Parse what the person typed: scheme defaults to https, path/query dropped.
	public static func normalizedBaseURL(_ raw: String) -> URL? {
		var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !text.isEmpty else { return nil }
		if !text.contains("://") { text = "https://" + text }
		guard var components = URLComponents(string: text),
			let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
			let host = components.host, !host.isEmpty
		else { return nil }
		components.scheme = scheme
		components.path = ""
		components.query = nil
		components.fragment = nil
		components.user = nil
		components.password = nil
		return components.url
	}
}
