import Foundation
import LHAPI
import Observation

/// The Settings tab's data: the settings record (written one whole section
/// at a time), the model catalog, provider keys, the custom endpoint and the
/// subscription connections. Saves take effect immediately, like the web.
@MainActor
@Observable
final class SettingsModel {
	private(set) var snapshot: SettingsSnapshot?
	private(set) var catalog: ModelCatalog?
	private(set) var keys: KeysResponse?
	private(set) var custom: CustomProviderStatus?
	private(set) var subscriptions: [SubscriptionStatus] = []
	private(set) var search: SearchStatus?
	private(set) var loadError: String?
	private(set) var keysError: String?
	/// A failed save, shown as an alert.
	var writeError: String?

	let client: APIClient
	private let app: AppModel
	@ObservationIgnored private var listener: UUID?

	init(client: APIClient, app: AppModel) {
		self.client = client
		self.app = app
	}

	func start() {
		guard listener == nil else { return }
		listener = app.events.subscribe { [weak self] signal in
			guard let self else { return }
			switch signal {
			case .reconnected:
				Task { await self.load() }
			case .event(let event) where event.type == "subscriptions-changed":
				Task {
					await self.reloadSubscriptions()
					await self.reloadCatalog()
				}
			default:
				break
			}
		}
		Task { await load() }
	}

	func load() async {
		async let catalog = try? client.modelCatalog()
		do {
			snapshot = try await client.settings()
			app.settingsRecord = snapshot?.record
			loadError = nil
		} catch {
			if snapshot == nil { loadError = Self.message(error) }
		}
		if let catalog = await catalog { self.catalog = catalog }
	}

	func reloadCatalog() async {
		if let fresh = try? await client.modelCatalog() { catalog = fresh }
	}

	/// Keys, then the custom endpoint and search status independently (a
	/// failure in one never blanks the others).
	func reloadKeys() async {
		do {
			keys = try await client.keyStatuses()
			keysError = nil
		} catch {
			if keys == nil { keysError = Self.message(error) }
		}
		if let fresh = try? await client.customProvider() { custom = fresh }
		await reloadSearch()
	}

	func reloadSearch() async {
		if let fresh = try? await client.searchStatus() { search = fresh }
	}

	func reloadSubscriptions() async {
		if let fresh = try? await client.subscriptionStatuses() { subscriptions = fresh }
	}

	func reloadCustom() async {
		if let fresh = try? await client.customProvider() { custom = fresh }
	}

	// MARK: The record

	var record: SettingsRecord? { snapshot?.record }
	var fileAccessError: String? { snapshot?.fileAccessError }
	func section(_ name: String) -> [String: JSONValue] { record?.section(name) ?? [:] }

	/// Replace one whole section; the stored record comes back clamped/healed.
	@discardableResult
	func write(_ section: String, _ value: [String: JSONValue]) async -> Bool {
		do {
			snapshot = try await client.putSettings(section, value)
			app.settingsRecord = snapshot?.record
			if section == "agent" { await reloadSearch() }
			if section == "models" { await reloadCatalog() }
			return true
		} catch {
			writeError = "\(section): \(Self.message(error))"
			return false
		}
	}

	// MARK: Keys

	/// nil on success, else the message to show beside the field.
	func saveKey(_ id: String, value: String) async -> String? {
		do {
			try await client.saveKey(id, value: value)
		} catch {
			return Self.message(error)
		}
		await reloadKeys()
		await reloadCatalog()
		return nil
	}

	func deleteKey(_ id: String) async {
		try? await client.deleteKey(id)
		await reloadKeys()
		await reloadCatalog()
	}

	// MARK: Subscriptions

	func subscription(_ providerId: String) -> SubscriptionStatus {
		subscriptions.first { $0.providerId == providerId } ?? SubscriptionStatus(empty: providerId)
	}

	var anySubscriptionPending: Bool { subscriptions.contains(where: \.pending) }

	static func message(_ error: any Error) -> String {
		(error as? APIError)?.message ?? error.localizedDescription
	}
}
