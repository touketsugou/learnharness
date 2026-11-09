import Foundation
import LHAPI
import LHCache
import Observation
import SwiftUI

/// App-wide state: the configured server, its API client and offline store.
@MainActor
@Observable
final class AppModel {
	private(set) var connection: ServerConnection?
	private(set) var client: APIClient?
	private(set) var store: OfflineStore?
	/// The server rejected the saved token (a 401): the connection screen
	/// asks for the current one, keeping the address and offline copies.
	private(set) var tokenWasRejected = false
	/// The one dictation run at a time.
	private(set) var dictation: DictationController?
	/// The visible tab.
	var tab: AppTab = .sessions
	/// A session to open (from the graph), consumed by the session list.
	var sessionRequest: String?
	/// The settings record the Settings tab last read or wrote; other
	/// screens follow it (the Graph tab's rendering switch).
	var settingsRecord: SettingsRecord?
	/// The native message to scroll to when that session opens.
	private var messageFocus: [String: String] = [:]
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
		// Reconnecting after a rejection to another server: the old one's
		// copies go, as on Sign Out.
		if tokenWasRejected, let store, connection?.baseURL != url { await store.clearAll() }
		try tokens.save(trimmed)
		defaults.set(url.absoluteString, forKey: Self.serverURLKey)
		activate(candidate)
	}

	/// Forget the token and this server's offline copies.
	func signOut() async {
		dictation?.cancel()
		dictation = nil
		await store?.clearAll()
		tokens.delete()
		defaults.removeObject(forKey: Self.serverURLKey)
		events.stop()
		connection = nil
		client = nil
		store = nil
		settingsRecord = nil
		tokenWasRejected = false
		tab = .sessions
	}

	/// A 401 from `rejected`'s client: leave for the connection screen. A late
	/// 401 from a connection already replaced is ignored.
	func tokenRejected(_ rejected: ServerConnection) {
		guard client != nil, connection == rejected else { return }
		tokenWasRejected = true
		dictation?.cancel()
		dictation = nil
		events.stop()
		client = nil
	}

	var serverAddress: String? { defaults.string(forKey: Self.serverURLKey) }

	/// Close the server connections in the background and reopen them on
	/// return (the server keeps running turns meanwhile).
	func sceneChanged(_ phase: ScenePhase) {
		switch phase {
		case .background: events.suspend()
		case .active: events.resume()
		default: break
		}
	}

	/// Switch to Sessions and open `chatId`, scrolled to `messageId` when given.
	func openSession(_ chatId: String, messageId: String?) {
		if let messageId { messageFocus[chatId] = messageId } else { messageFocus[chatId] = nil }
		sessionRequest = chatId
		tab = .sessions
	}

	func takeMessageFocus(for chatId: String) -> String? { messageFocus.removeValue(forKey: chatId) }

	func stashOpening(_ text: String, for chatId: String) { openingPrompts[chatId] = text }
	func takeOpening(for chatId: String) -> String? { openingPrompts.removeValue(forKey: chatId) }

	private func activate(_ connection: ServerConnection) {
		self.connection = connection
		tokenWasRejected = false
		let client = APIClient(connection: connection, onUnauthorized: { [weak self] in
			Task { @MainActor in self?.tokenRejected(connection) }
		})
		self.client = client
		store = OfflineStore.forServer(connection.baseURL)
		dictation = DictationController(client: client)
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

enum AppTab: Hashable {
	case sessions
	case graph
	case settings
}
