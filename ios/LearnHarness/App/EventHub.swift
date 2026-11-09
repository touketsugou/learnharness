import Foundation
import LHAPI

/// One shared GET /api/events connection for the whole app, re-established
/// with backoff. Listeners get every notification; after a reconnect they
/// get `.reconnected` and should refetch (the server keeps no replay).
/// In the background the connection is closed (`.suspended`: listeners close
/// their own streams) and reopened at once on return.
@MainActor
final class EventHub {
	enum Signal {
		case event(ServerEvent)
		case reconnected
		case suspended
	}

	private var listeners: [UUID: (Signal) -> Void] = [:]
	private var task: Task<Void, Never>?
	private var client: APIClient?
	private var suspended = false

	func start(client: APIClient) {
		self.client = client
		suspended = false
		run(client, announceReconnect: false)
	}

	/// The app went to the background: close the connection.
	func suspend() {
		guard client != nil, !suspended else { return }
		suspended = true
		task?.cancel()
		task = nil
		dispatch(.suspended)
	}

	/// Back in the foreground: reconnect now, without waiting out a backoff.
	func resume() {
		guard let client, suspended else { return }
		suspended = false
		run(client, announceReconnect: true)
	}

	private func run(_ client: APIClient, announceReconnect: Bool) {
		task?.cancel()
		task = Task { [weak self] in
			var delay: Duration = .seconds(1)
			var first = !announceReconnect
			while !Task.isCancelled {
				do {
					let stream = client.serverEvents()
					if !first { self?.dispatch(.reconnected) }
					first = false
					for try await event in stream {
						delay = .seconds(1)
						self?.dispatch(.event(event))
					}
				} catch {
					// Transport errors and 401s retry with backoff; the views
					// surface their own request failures.
				}
				try? await Task.sleep(for: delay)
				delay = min(delay * 2, .seconds(30))
			}
		}
	}

	func stop() {
		task?.cancel()
		task = nil
		client = nil
		suspended = false
	}

	@discardableResult
	func subscribe(_ listener: @escaping (Signal) -> Void) -> UUID {
		let id = UUID()
		listeners[id] = listener
		return id
	}

	func unsubscribe(_ id: UUID) {
		listeners[id] = nil
	}

	private func dispatch(_ signal: Signal) {
		for listener in listeners.values { listener(signal) }
	}
}
