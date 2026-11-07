import Foundation
import LHAPI
import LHCache
import Observation

/// App-wide state: the configured server, its API client and offline store.
@MainActor
@Observable
final class AppModel {
	private(set) var connection: ServerConnection?
	private(set) var client: APIClient?
	private(set) var store: OfflineStore?
	let events = EventHub()
	/// The first message of a just-created session, sent once it opens
	/// (the web's stashed opening prompt).
	private var openingPrompts: [String: String] = [:]

	private let tokens: TokenStore
	private let defaults: UserDefaults
	private static let serverURLKey = "serverURL"

	init(tokens: TokenStore = KeychainTokenStore(), defaults: UserDefaults = .standard) {
		self.tokens = tokens
		self.defaults = defaults
		if let raw = defaults.string(forKey: Self.serverURLKey), let url = URL(string: raw), let token = tokens.read() {
			activate(ServerConnection(baseURL: url, token: token))
		}
	}

	/// Verify the address and token against the server, then remember them.
	func connect(address: String, token: String) async throws {
		guard let url = ServerConnection.normalizedBaseURL(address) else { throw ConnectionError.invalidAddress }
		let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { throw ConnectionError.missingToken }
		let candidate = ServerConnection(baseURL: url, token: trimmed)
		try await APIClient(connection: candidate).verifyConnection()
		try tokens.save(trimmed)
		defaults.set(url.absoluteString, forKey: Self.serverURLKey)
		activate(candidate)
	}

	/// Forget the token and this server's offline copies.
	func signOut() async {
		await store?.clearAll()
		tokens.delete()
		defaults.removeObject(forKey: Self.serverURLKey)
		events.stop()
		connection = nil
		client = nil
		store = nil
	}

	var serverAddress: String? { defaults.string(forKey: Self.serverURLKey) }

	func stashOpening(_ text: String, for chatId: String) { openingPrompts[chatId] = text }
	func takeOpening(for chatId: String) -> String? { openingPrompts.removeValue(forKey: chatId) }

	private func activate(_ connection: ServerConnection) {
		self.connection = connection
		let client = APIClient(connection: connection)
		self.client = client
		store = OfflineStore.forServer(connection.baseURL)
		events.start(client: client)
	}
}

enum ConnectionError: LocalizedError {
	case invalidAddress
	case missingToken

	var errorDescription: String? {
		switch self {
		case .invalidAddress: "Enter the server address, for example learn.example.com."
		case .missingToken: "Enter the access token configured on the server."
		}
	}
}
