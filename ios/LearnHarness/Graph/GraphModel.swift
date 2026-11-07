import Foundation
import LHAPI
import LHCache
import Observation

/// The knowledge graph tab's data: the snapshot (cached for offline
/// reading), the source directory, render settings and running extractions.
/// Refreshes on server notifications; mutations go through here.
@MainActor
@Observable
final class GraphModel {
	private(set) var snapshot: GraphSnapshot?
	private(set) var directory: SourceDirectory?
	private(set) var settings = GraphRenderSettings()
	private(set) var runs: [ExtractionRun] = []
	private(set) var offline = false
	private(set) var loading = false
	/// The graph settings' rendering switch: off shows the chains view.
	private(set) var rendering = true
	var error: String?
	let imports: NotesImportQueue

	private let client: APIClient
	private let store: OfflineStore
	private let events: EventHub
	@ObservationIgnored private var listener: UUID?

	init(client: APIClient, store: OfflineStore, events: EventHub) {
		self.client = client
		self.store = store
		self.events = events
		imports = NotesImportQueue(client: client)
	}

	func start() {
		guard listener == nil else { return }
		listener = events.subscribe { [weak self] signal in self?.handle(signal) }
		Task { await reload() }
	}

	func reload() async {
		loading = snapshot == nil
		defer { loading = false }
		async let settings = try? client.graphRenderSettings()
		async let runs = try? client.extractionRuns()
		async let record = try? client.settings()
		await reloadGraph()
		if let settings = await settings { self.settings = settings }
		if let runs = await runs { self.runs = runs }
		if let record = await record { applySettings(record.record) }
	}

	/// Follow a settings write (the Settings tab saved the graph section).
	func applySettings(_ record: SettingsRecord) {
		rendering = record.section("graph")["rendering"]?.boolValue ?? true
	}

	/// Snapshot + source directory; the offline copy when the server is unreachable.
	func reloadGraph() async {
		do {
			async let directory = try? client.sourceDirectory()
			let fresh = try await client.graphSnapshot()
			snapshot = fresh
			offline = false
			if let directory = await directory { self.directory = directory }
			if let data = try? JSONEncoder().encode(fresh) { try? await store.saveGraph(data) }
		} catch APIError.transport {
			offline = true
			if snapshot == nil, let data = await store.loadGraph() {
				snapshot = try? JSONDecoder().decode(GraphSnapshot.self, from: data)
			}
			if snapshot == nil { error = "The server can’t be reached and the graph has no offline copy." }
		} catch is CancellationError {
		} catch {
			self.error = (error as? APIError)?.message ?? error.localizedDescription
		}
	}

	private func handle(_ signal: EventHub.Signal) {
		switch signal {
		case .reconnected:
			Task { await reload() }
		case .event(let event):
			switch event.type {
			case "activity-changed":
				Task { await refreshRuns() }
			case "sources-changed", "chats-changed":
				Task { await reloadGraph() }
			default:
				break
			}
		}
	}

	/// A run leaving the feed means its merge just landed: refetch the graph.
	private func refreshRuns() async {
		guard let fresh = try? await client.extractionRuns() else { return }
		let finished = !Set(runs.map(\.id)).subtracting(fresh.map(\.id)).isEmpty
		runs = fresh
		if finished { await reloadGraph() }
	}

	// MARK: Mutations

	func deleteNode(_ id: String) async throws {
		try await client.deleteGraphNode(id)
		await reloadGraph()
	}

	func change(_ action: SourceAction) async throws {
		directory = try await client.changeSources(action)
		await reloadGraph()
	}

	func deleteSources(sourceIds: [String], folderIds: [String], deleteSessions: Bool) async throws {
		directory = try await client.deleteSources(sourceIds: sourceIds, folderIds: folderIds, deleteSessions: deleteSessions)
		await reloadGraph()
	}
}
