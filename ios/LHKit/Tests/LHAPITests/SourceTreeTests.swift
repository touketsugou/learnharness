import Foundation
import Testing
@testable import LHAPI

@Suite("Source tree")
struct SourceTreeTests {
	private func node(_ id: String, _ source: String, name: String? = nil) -> GraphProposition {
		GraphProposition(id: id, name: name ?? id.uppercased(), statement: "\(id) statement", provenance: [ProvenancePoint(chatId: source, messageId: "")])
	}

	private var snapshot: GraphSnapshot {
		GraphSnapshot(
			propositions: [node("a", "s1"), node("b", "s1"), node("c", "s2"), node("d", "s2", name: "Lonely"), node("p", "prac")],
			sessions: ["s1": "Session one", "prac": "Drill"],
			fileSources: ["s2": "notes/kepler.md"],
			chains: [GraphChain(id: "arg_1", premises: ["a", "c"], conclusion: "b")]
		)
	}

	private var directory: SourceDirectory {
		SourceDirectory(
			organization: SourceOrganization(
				folders: [SourceFolder(id: "f1", name: "Physics", parentId: nil), SourceFolder(id: "f2", name: "Orbits", parentId: "f1")],
				placements: ["s2": SourcePlacement(folderId: "f2", name: nil)]
			),
			sources: [
				SourceEntry(id: "s1", kind: "chat", chatKind: .teach, label: "Session one", filePath: nil),
				SourceEntry(id: "s2", kind: "notes", chatKind: nil, label: "kepler", filePath: "notes/kepler.md"),
				SourceEntry(id: "empty", kind: "chat", chatKind: .teach, label: "No graph yet", filePath: nil),
				SourceEntry(id: "prac", kind: "chat", chatKind: .practice, label: "Drill", filePath: nil),
			]
		)
	}

	@Test func chainsLiveWithTheirConclusionAndLonelyNodesStandAlone() throws {
		let tree = SourceTree.build(snapshot: snapshot, directory: directory)
		let s1 = try #require(tree.groups.first { $0.id == "s1" })
		#expect(s1.chains.map(\.id) == ["arg_1"])
		#expect(s1.singletons.isEmpty)
		#expect(s1.nodeCount == 2)
		let s2 = try #require(tree.groups.first { $0.id == "s2" })
		#expect(s2.chains.isEmpty)
		#expect(s2.singletons.map(\.id) == ["d"])
		#expect(s2.folderId == "f2")
		#expect(tree.groups.contains { $0.id == "empty" && $0.isEmpty })
		#expect(!tree.groups.contains { $0.id == "prac" })
	}

	@Test func foldersNestAndGuardMoves() {
		let tree = SourceTree.build(snapshot: snapshot, directory: directory)
		#expect(tree.folders(in: nil).map(\.id) == ["f1"])
		#expect(tree.folders(in: "f1").map(\.id) == ["f2"])
		#expect(tree.groups(in: "f2").map(\.id) == ["s2"])
		#expect(tree.groups(in: nil).map(\.label) == ["No graph yet", "Session one"])
		#expect(tree.isWithin("f2", folder: "f1"))
		#expect(!tree.isWithin(nil, folder: "f1"))
		#expect(!tree.isEmptyFolder("f1"))
		#expect(!tree.isEmptyFolder("f2"))
	}

	@Test func goneSourcesAreUnlabeledAndSortLast() {
		var snap = snapshot
		snap.propositions.append(node("z", "gone"))
		let tree = SourceTree.build(snapshot: snap, directory: directory)
		let groups = tree.groups(in: nil)
		#expect(groups.last?.id == "gone")
		#expect(groups.last?.label == "unlabeled")
		#expect(groups.last?.isUnlabeled == true)
	}

	@Test func sortingByPropositionCount() {
		let tree = SourceTree.build(snapshot: snapshot, directory: directory)
		#expect(tree.groups(in: nil, sort: .props, ascending: false).map(\.id) == ["s1", "empty"])
	}

	@Test func searchNarrowsToMatchingChainsAndNodes() {
		let tree = SourceTree.build(snapshot: snapshot, directory: directory)
		let hits = tree.searched("lonely", snapshot: snapshot)
		#expect(hits.map(\.id) == ["s2"])
		#expect(hits.first?.singletons.map(\.id) == ["d"])
		#expect(tree.searched("c statement", snapshot: snapshot).map(\.id) == ["s1"])
	}
}
