import Foundation
import LHAPI

/// One shared GET /api/events connection for the whole app, re-established
/// with backoff. Listeners get every notification; after a reconnect they
/// get `.reconnected` and should refetch (the server keeps no replay).
@MainActor
final class EventHub {
	enum Signal {
		case event(ServerEvent)
		case reconnected
	}

	private var listeners: [UUID: (Signal) -> Void] = [:]
	private var task: Task<Void, Never>?

	func start(client: APIClient) {
		task?.cancel()
		task = Task { [weak self] in
			var delay: Duration = .seconds(1)
			var first = true
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
