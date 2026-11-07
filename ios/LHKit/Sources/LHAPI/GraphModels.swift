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

public struct GraphSnapshot: Sendable, Hashable, Codable {
	public var propositions: [GraphProposition]
	/// Source id → session title.
	public var sessions: [String: String]
	/// Source id → imported file path.
	public var fileSources: [String: String]
}

public struct SourcePlacement: Sendable, Hashable, Codable {
	public var folderId: String?
	public var name: String?
}

public struct SourceFolder: Sendable, Hashable, Codable, Identifiable {
	public var id: String
	public var name: String
	public var parentId: String?
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
}

public struct SourceDirectory: Sendable, Hashable, Codable {
	public var organization: SourceOrganization
	public var sources: [SourceEntry]
}

extension APIClient {
	public func graphSnapshot() async throws -> GraphSnapshot {
		try await get("/api/graph", as: GraphSnapshot.self)
	}

	public func sourceDirectory() async throws -> SourceDirectory {
		try await get("/api/graph/sources", as: SourceDirectory.self)
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
