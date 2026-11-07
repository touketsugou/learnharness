import Foundation

/// The chains & sources manager's structure (web chain table): folders →
/// sources → reasoning chains (a chain lives where its conclusion was born)
/// plus lonely propositions. Practice sessions are not listed.
public struct SourceTree: Sendable {
	public struct Group: Sendable, Identifiable {
		public var id: String
		public var entry: SourceEntry?
		/// The display name; "unlabeled" when the source is gone and nameless.
		public var label: String
		public var isUnlabeled = false
		public var folderId: String?
		public var chains: [GraphChain]
		/// Propositions born here that take part in no chain.
		public var singletons: [GraphProposition]
		/// Propositions born here.
		public var nodeCount: Int

		public var isEmpty: Bool { chains.isEmpty && singletons.isEmpty }
	}

	public enum Sort: String, Sendable, CaseIterable {
		case name, props, created
	}

	public var folders: [SourceFolder]
	public var groups: [Group]

	public static func build(snapshot: GraphSnapshot, directory: SourceDirectory?) -> SourceTree {
		let entries = Dictionary((directory?.sources ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
		let placements = directory?.organization.placements ?? [:]
		let byId = Dictionary(snapshot.propositions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
		func birth(_ id: String) -> String? { byId[id]?.birthSource }

		var chains: [String: [GraphChain]] = [:]
		var inChain = Set<String>()
		for chain in snapshot.chains {
			inChain.formUnion(chain.premises)
			inChain.insert(chain.conclusion)
			if let source = birth(chain.conclusion) { chains[source, default: []].append(chain) }
		}
		var singletons: [String: [GraphProposition]] = [:]
		var counts: [String: Int] = [:]
		for proposition in snapshot.propositions {
			guard let source = proposition.birthSource else { continue }
			counts[source, default: 0] += 1
			if !inChain.contains(proposition.id) { singletons[source, default: []].append(proposition) }
		}

		var ids = Set(entries.keys)
		ids.formUnion(chains.keys)
		ids.formUnion(singletons.keys)
		let groups: [Group] = ids.compactMap { id in
			let entry = entries[id]
			if entry?.chatKind == .practice { return nil }
			let label = placements[id]?.name.flatMap { $0.isEmpty ? nil : $0 }
				?? entry?.label.flatMap { $0.isEmpty ? nil : $0 }
				?? snapshot.sourceLabel(id)
			return Group(id: id, entry: entry, label: label ?? "unlabeled", isUnlabeled: label == nil, folderId: placements[id]?.folderId,
						 chains: chains[id] ?? [], singletons: singletons[id] ?? [], nodeCount: counts[id] ?? 0)
		}
		return SourceTree(folders: directory?.organization.folders ?? [], groups: groups)
	}

	public func folders(in parent: String?, sort: Sort = .name, ascending: Bool = true) -> [SourceFolder] {
		let list = folders.filter { $0.parentId == parent }
		let sorted = list.sorted { a, b in
			switch sort {
			case .created: (a.createdAt ?? "") < (b.createdAt ?? "")
			default: a.name.localizedStandardCompare(b.name) == .orderedAscending
			}
		}
		return ascending ? sorted : sorted.reversed()
	}

	public func groups(in parent: String?, sort: Sort = .name, ascending: Bool = true) -> [Group] {
		Self.sorted(groups.filter { $0.folderId == parent }, by: sort, ascending: ascending)
	}

	public static func sorted(_ groups: [Group], by sort: Sort, ascending: Bool) -> [Group] {
		let list = groups.sorted { a, b in
			let order: ComparisonResult = switch sort {
			// Unlabeled sources sort after every name (web "\uffff" key).
			case .name: a.isUnlabeled != b.isUnlabeled ? (a.isUnlabeled ? .orderedDescending : .orderedAscending) : a.label.localizedStandardCompare(b.label)
			case .props: a.nodeCount == b.nodeCount ? .orderedSame : (a.nodeCount < b.nodeCount ? .orderedAscending : .orderedDescending)
			case .created: (a.entry?.createdAt ?? "").compare(b.entry?.createdAt ?? "")
			}
			// Ties break on the id so equal names keep one stable order.
			return order == .orderedSame ? a.id < b.id : order == .orderedAscending
		}
		return ascending ? list : list.reversed()
	}

	/// Groups narrowed to chains and propositions matching `query` (name or
	/// statement of any member); groups without a match are dropped.
	public func searched(_ query: String, snapshot: GraphSnapshot) -> [Group] {
		let byId = Dictionary(snapshot.propositions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
		func hit(_ id: String) -> Bool {
			guard let node = byId[id] else { return false }
			return GraphGeometry.matches(name: node.name, statement: node.statement, query: query)
		}
		return groups.compactMap { group in
			var narrowed = group
			narrowed.chains = group.chains.filter { ($0.premises + [$0.conclusion]).contains(where: hit) }
			narrowed.singletons = group.singletons.filter { hit($0.id) }
			let nameHit = group.label.localizedCaseInsensitiveContains(query.trimmingCharacters(in: .whitespaces))
			return narrowed.isEmpty && !nameHit ? nil : (nameHit && narrowed.isEmpty ? group : narrowed)
		}
	}

	/// Whether `folder` (or a descendant) is `candidate` — a folder can't move into itself.
	public func isWithin(_ candidate: String?, folder: String) -> Bool {
		var next = candidate
		while let current = next {
			if current == folder { return true }
			next = folders.first { $0.id == current }?.parentId
		}
		return false
	}

	/// A folder with no subfolders and no sources (only those can be removed).
	public func isEmptyFolder(_ id: String) -> Bool {
		!folders.contains { $0.parentId == id } && !groups.contains { $0.folderId == id }
	}
}
