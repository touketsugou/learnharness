import Foundation
import Testing
@testable import LHAPI

@Suite("Practice material")
struct PracticeMaterialTests {
	func proposition(_ id: String, _ source: String) -> GraphProposition {
		GraphProposition(id: id, name: id.uppercased(), statement: "\(id) holds", provenance: [ProvenancePoint(chatId: source, messageId: "m")])
	}

	@Test func groupsByBirthSourceHidingPracticeSessions() {
		let snapshot = GraphSnapshot(
			propositions: [proposition("a", "chat_t"), proposition("b", "notes_1"), proposition("c", "chat_p"), proposition("d", "chat_t")],
			sessions: ["chat_t": "Bayes", "chat_p": "Drills"],
			fileSources: ["notes_1": "/notes/learn database.md"]
		)
		let directory = SourceDirectory(
			organization: SourceOrganization(folders: [], placements: [:]),
			sources: [
				SourceEntry(id: "chat_t", kind: "chat", chatKind: .teach, label: nil, filePath: nil),
				SourceEntry(id: "chat_p", kind: "chat", chatKind: .practice, label: nil, filePath: nil),
			]
		)
		let groups = PracticeMaterial.groups(snapshot: snapshot, directory: directory)
		#expect(groups.map(\.label) == ["Bayes", "learn database"])
		#expect(groups.first?.propositions.map(\.id) == ["a", "d"])
	}

	@Test func renamedPlacementsWin() {
		let snapshot = GraphSnapshot(propositions: [proposition("a", "s")], sessions: ["s": "Old"], fileSources: [:])
		let directory = SourceDirectory(organization: SourceOrganization(folders: [], placements: ["s": SourcePlacement(folderId: nil, name: "Renamed")]), sources: [])
		#expect(PracticeMaterial.groups(snapshot: snapshot, directory: directory).first?.label == "Renamed")
		#expect(PracticeMaterial.fileLabel("C:\\x\\a.b.md") == "a.b")
	}

	@Test func decodesTheGoldenGraph() throws {
		let url = Fixtures.directory.deletingLastPathComponent().appending(path: "golden-data/graph/sources.json")
		#expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
	}
}

@Suite struct ThinkingLevelTests {
	@Test func defaultFollowsTheOrdering() {
		#expect(ThinkingLevels.defaultLevel(["off", "low", "medium", "high"]) == "medium")
		#expect(ThinkingLevels.defaultLevel(["off", "low", "high"]) == "low")
		#expect(ThinkingLevels.defaultLevel(["off"]) == "off")
		#expect(ThinkingLevels.defaultLevel([]) == "off")
	}

	@Test func explicitLevelRides() {
		#expect(ThinkingLevels.populate("high", supported: ["off"]) == "high")
		#expect(ThinkingLevels.populate(nil, supported: ["off", "minimal"]) == "minimal")
	}

	@Test func prettyNameDropsTheVendorPrefix() {
		#expect(prettyModelName("anthropic/claude-x") == "claude-x")
		#expect(prettyModelName("gpt-5") == "gpt-5")
	}
}
