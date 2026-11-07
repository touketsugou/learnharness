import Foundation

// GET /api/graph (GraphSnapshot) and GET /api/graph/sources (SourceDirectory):
// the parts the app reads. Unknown fields are ignored.

public struct ProvenancePoint: Sendable, Hashable, Codable {
	public var chatId: String
	public var messageId: String
}

public struct GraphProposition: Sendable, Hashable, Codable, Identifiable {
	public var id: String
	public var name: String
	public var statement: String
	public var provenance: [ProvenancePoint]

	/// The birth source (the session or notes file it was first extracted from).
	public var birthSource: String? { provenance.first?.chatId }
}

public struct GraphEdge: Sendable, Hashable, Codable {
	public var from: String
	public var to: String

	public init(from: String, to: String) {
		self.from = from
		self.to = to
	}
}

/** One stored reasoning chain: premises that jointly entail the conclusion. */
public struct GraphChain: Sendable, Hashable, Codable, Identifiable {
	public var id: String
	public var premises: [String]
	public var conclusion: String
	public var provenance: [ProvenancePoint]
	public var createdAt: String?

	public init(id: String, premises: [String], conclusion: String, provenance: [ProvenancePoint] = [], createdAt: String? = nil) {
		self.id = id
		self.premises = premises
		self.conclusion = conclusion
		self.provenance = provenance
		self.createdAt = createdAt
	}
}

/** A birth-session cluster: member node ids and its label (nil until named). */
public struct GraphCluster: Sendable, Hashable, Codable, Identifiable {
	public var id: String
	public var label: String?
	public var members: [String]

	public init(id: String, label: String?, members: [String]) {
		self.id = id
		self.label = label
		self.members = members
	}
}

public struct GraphPosition: Sendable, Hashable, Codable {
	public var x: Double
	public var y: Double

	public init(x: Double, y: Double) {
		self.x = x
		self.y = y
	}
}

/** GET /api/graph. `nodes` adds the derived implication nodes (id "arg_…",
 *  one per multi-premise chain) to the stored `propositions`. */
public struct GraphSnapshot: Sendable, Hashable, Codable {
	public var propositions: [GraphProposition]
	/// Source id → session title.
	public var sessions: [String: String]
	/// Source id → imported file path.
	public var fileSources: [String: String]
	public var nodes: [GraphProposition] = []
	public var edges: [GraphEdge] = []
	public var chains: [GraphChain] = []
	public var clusters: [GraphCluster] = []
	/// Resting layout positions (written by the server after every merge).
	public var positions: [String: GraphPosition] = [:]

	private enum CodingKeys: String, CodingKey {
		case propositions, sessions, fileSources, nodes, edges, chains, clusters, positions
	}

	public init(propositions: [GraphProposition], sessions: [String: String], fileSources: [String: String],
				nodes: [GraphProposition] = [], edges: [GraphEdge] = [], chains: [GraphChain] = [],
				clusters: [GraphCluster] = [], positions: [String: GraphPosition] = [:]) {
		self.propositions = propositions
		self.sessions = sessions
		self.fileSources = fileSources
		self.nodes = nodes
		self.edges = edges
		self.chains = chains
		self.clusters = clusters
		self.positions = positions
	}

	public init(from decoder: any Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		propositions = try c.decodeIfPresent([GraphProposition].self, forKey: .propositions) ?? []
		sessions = try c.decodeIfPresent([String: String].self, forKey: .sessions) ?? [:]
		fileSources = try c.decodeIfPresent([String: String].self, forKey: .fileSources) ?? [:]
		nodes = try c.decodeIfPresent([GraphProposition].self, forKey: .nodes) ?? []
		edges = try c.decodeIfPresent([GraphEdge].self, forKey: .edges) ?? []
		chains = try c.decodeIfPresent([GraphChain].self, forKey: .chains) ?? []
		clusters = try c.decodeIfPresent([GraphCluster].self, forKey: .clusters) ?? []
		positions = try c.decodeIfPresent([String: GraphPosition].self, forKey: .positions) ?? [:]
	}

	/// Implication nodes are pure geometry (the junction of a multi-premise chain).
	public static func isImplication(_ id: String) -> Bool { id.hasPrefix("arg_") }

	/// The session or notes-file name for a source id.
	public func sourceLabel(_ id: String) -> String? {
		if let title = sessions[id] { return title }
		if let path = fileSources[id] { return PracticeMaterial.fileLabel(path) }
		return nil
	}
}

/** The canvas settings the app reads from GET /api/graph/render-settings
 *  (sizes in world units; labelZoom is the camera-ratio gate). Defaults
 *  match src/core/render-settings.ts DEFAULT_RENDER_SETTINGS. */
public struct GraphRenderSettings: Sendable, Hashable, Codable {
	public struct Regions: Sendable, Hashable, Codable {
		public var dilation: Double = 20
		public var blur: Double = 40
		public var edgeAlpha: Double = 0.2
		public var enabled: Bool = true

		public init() {}

		public init(from decoder: any Decoder) throws {
			let c = try decoder.container(keyedBy: CodingKeys.self)
			let d = Regions()
			dilation = try c.decodeIfPresent(Double.self, forKey: .dilation) ?? d.dilation
			blur = try c.decodeIfPresent(Double.self, forKey: .blur) ?? d.blur
			edgeAlpha = try c.decodeIfPresent(Double.self, forKey: .edgeAlpha) ?? d.edgeAlpha
			enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
		}
	}

	public var nodeSize: Double = 2
	public var edgeWidth: Double = 1
	public var arrowLength: Double = 2
	public var labelZoom: Double = 0.5
	public var labelSize: Double = 3
	public var clusterLabels: Bool = true
	public var clusterLabelSize: Double = 14
	public var regions = Regions()

	public init() {}

	public init(from decoder: any Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		let d = GraphRenderSettings()
		nodeSize = try c.decodeIfPresent(Double.self, forKey: .nodeSize) ?? d.nodeSize
		edgeWidth = try c.decodeIfPresent(Double.self, forKey: .edgeWidth) ?? d.edgeWidth
		arrowLength = try c.decodeIfPresent(Double.self, forKey: .arrowLength) ?? d.arrowLength
		labelZoom = try c.decodeIfPresent(Double.self, forKey: .labelZoom) ?? d.labelZoom
		labelSize = try c.decodeIfPresent(Double.self, forKey: .labelSize) ?? d.labelSize
		clusterLabels = try c.decodeIfPresent(Bool.self, forKey: .clusterLabels) ?? d.clusterLabels
		clusterLabelSize = try c.decodeIfPresent(Double.self, forKey: .clusterLabelSize) ?? d.clusterLabelSize
		regions = try c.decodeIfPresent(Regions.self, forKey: .regions) ?? d.regions
	}
}

/** One running background extraction (GET /api/graph/status). */
public struct ExtractionRun: Sendable, Hashable, Codable, Identifiable {
	public var id: String
	public var chatId: String
	public var title: String
	/// queued | extracting | waiting | auditing | merging.
	public var phase: String
}

public struct SourcePlacement: Sendable, Hashable, Codable {
	public var folderId: String?
	public var name: String?
}

public struct SourceFolder: Sendable, Hashable, Codable, Identifiable {
	public var id: String
	public var name: String
	public var parentId: String?
	public var createdAt: String?
}

public struct SourceOrganization: Sendable, Hashable, Codable {
	public var folders: [SourceFolder]
	public var placements: [String: SourcePlacement]
}

public struct SourceEntry: Sendable, Hashable, Codable, Identifiable {
	public var id: String
	/// chat | notes | missing.
	public var kind: String
	public var chatKind: ChatKind?
	public var label: String?
	public var filePath: String?
	public var createdAt: String?
}

public struct SourceDirectory: Sendable, Hashable, Codable {
	public var organization: SourceOrganization
	public var sources: [SourceEntry]
}

/** POST /api/graph/sources organization actions (src/core/source-organization.ts). */
public enum SourceAction: Sendable, Hashable, Encodable {
	case createFolder(name: String, parentId: String?)
	case renameFolder(id: String, name: String)
	case renameSource(id: String, name: String)
	case moveSource(id: String, parentId: String?)
	case moveFolder(id: String, parentId: String?)
	case deleteFolder(id: String)

	private enum CodingKeys: String, CodingKey { case action, id, name, parentId, kind }

	public func encode(to encoder: any Encoder) throws {
		var c = encoder.container(keyedBy: CodingKeys.self)
		switch self {
		case .createFolder(let name, let parentId):
			try c.encode("create-folder", forKey: .action)
			try c.encode(name, forKey: .name)
			try c.encode(parentId, forKey: .parentId)
		case .renameFolder(let id, let name):
			try c.encode("rename-folder", forKey: .action)
			try c.encode(id, forKey: .id)
			try c.encode(name, forKey: .name)
		case .renameSource(let id, let name):
			try c.encode("rename-source", forKey: .action)
			try c.encode(id, forKey: .id)
			try c.encode(name, forKey: .name)
		case .moveSource(let id, let parentId), .moveFolder(let id, let parentId):
			try c.encode("move", forKey: .action)
			try c.encode(id, forKey: .id)
			if case .moveSource = self { try c.encode("source", forKey: .kind) } else { try c.encode("folder", forKey: .kind) }
			try c.encode(parentId, forKey: .parentId)
		case .deleteFolder(let id):
			try c.encode("delete-folder", forKey: .action)
			try c.encode(id, forKey: .id)
		}
	}
}

/** One file's outcome from POST /api/graph/import. */
public struct NotesImportResult: Sendable, Hashable, Codable {
	public var filePath: String
	public var ok: Bool
	/// completed | failed | partial | aborted | busy.
	public var outcome: String
	public var error: String?
	public var code: String?
	public var notice: String?
}

/** A notes file to import: its folder-relative path and bytes. */
public struct NotesFile: Sendable, Hashable {
	/// "notes.md", or "Folder/sub/notes.md" for a folder import.
	public var path: String
	public var data: Data

	public init(path: String, data: Data) {
		self.path = path
		self.data = data
	}

	public var name: String { path.split(separator: "/").last.map(String.init) ?? path }
}

extension APIClient {
	public func graphSnapshot() async throws -> GraphSnapshot {
		try await get("/api/graph", as: GraphSnapshot.self)
	}

	public func sourceDirectory() async throws -> SourceDirectory {
		try await get("/api/graph/sources", as: SourceDirectory.self)
	}

	public func graphRenderSettings() async throws -> GraphRenderSettings {
		try await get("/api/graph/render-settings", as: GraphRenderSettings.self)
	}

	public func extractionRuns() async throws -> [ExtractionRun] {
		struct Response: Decodable { var runs: [ExtractionRun] }
		return try await get("/api/graph/status", as: Response.self).runs
	}

	@discardableResult
	public func changeSources(_ action: SourceAction) async throws -> SourceDirectory {
		let (data, _) = try await send(try json("POST", "/api/graph/sources", body: action))
		return try decode(SourceDirectory.self, from: data)
	}

	/// Delete sources and folders; `deleteSessions` also deletes selected chats.
	@discardableResult
	public func deleteSources(sourceIds: [String], folderIds: [String], deleteSessions: Bool) async throws -> SourceDirectory {
		struct Body: Encodable { var sourceIds: [String]; var folderIds: [String]; var deleteSessions: Bool }
		let (data, _) = try await send(try json("DELETE", "/api/graph/sources",
			body: Body(sourceIds: sourceIds, folderIds: folderIds, deleteSessions: deleteSessions)))
		return try decode(SourceDirectory.self, from: data)
	}

	/// Delete one node and every chain touching it (permanent).
	public func deleteGraphNode(_ id: String) async throws {
		let path = "/api/graph/nodes/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? id)"
		try await send(makeRequest("DELETE", path))
	}

	/// Extract one notes file into the graph. The server runs the whole
	/// extraction inside the request, so it can take minutes.
	public func importNotes(_ file: NotesFile) async throws -> NotesImportResult {
		struct Response: Decodable { var results: [NotesImportResult]; var error: String? }
		let boundary = "lh-\(UUID().uuidString)"
		let name = file.name.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
		var body = Data()
		body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"files\"; filename=\"\(name)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
		body.append(file.data)
		body.append(Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"paths\"\r\n\r\n".utf8))
		body.append(Data(file.path.utf8))
		body.append(Data("\r\n--\(boundary)--\r\n".utf8))
		var request = makeRequest("POST", "/api/graph/import", body: body, contentType: "multipart/form-data; boundary=\(boundary)")
		request.timeoutInterval = 60 * 30
		let (data, _) = try await send(request)
		let response = try decode(Response.self, from: data)
		guard let result = response.results.first else {
			throw APIError.decoding(response.error ?? "The import returned no result.")
		}
		return result
	}
}

/// Practice material: propositions grouped by birth source, the web chain
/// table's grouping (practice-session sources hidden, src/core
/// chainSourceDirectory), labelled like the web (renamed placement → entry
/// label → session title → file name without extension).
public enum PracticeMaterial {
	public struct Group: Sendable, Hashable, Identifiable {
		public var id: String
		public var label: String
		public var propositions: [GraphProposition]
	}

	public static func groups(snapshot: GraphSnapshot, directory: SourceDirectory?) -> [Group] {
		let entries = Dictionary((directory?.sources ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
		var bySource: [String: [GraphProposition]] = [:]
		var order: [String] = []
		for proposition in snapshot.propositions {
			guard let source = proposition.birthSource else { continue }
			if entries[source]?.chatKind == .practice { continue }
			if bySource[source] == nil { order.append(source) }
			bySource[source, default: []].append(proposition)
		}
		return order.map { source in
			Group(id: source, label: label(source, snapshot: snapshot, directory: directory, entry: entries[source]),
				  propositions: bySource[source] ?? [])
		}
		.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
	}

	static func label(_ source: String, snapshot: GraphSnapshot, directory: SourceDirectory?, entry: SourceEntry?) -> String {
		if let renamed = directory?.organization.placements[source]?.name, !renamed.isEmpty { return renamed }
		if let label = entry?.label, !label.isEmpty { return label }
		if let title = snapshot.sessions[source], !title.isEmpty { return title }
		if let path = snapshot.fileSources[source] { return fileLabel(path) }
		return "Untitled source"
	}

	/// src/core/source-label.ts sourceFileLabel.
	static func fileLabel(_ path: String) -> String {
		let base = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
		guard let dot = base.lastIndex(of: "."), dot != base.startIndex else { return base }
		return String(base[..<dot])
	}
}
