import Foundation
import Testing
@testable import LHAPI

@Suite("Graph models")
struct GraphModelTests {
	@Test func snapshotDecodesTheCanvasFields() throws {
		let json = #"""
		{
		  "nodes": [
		    {"id":"n_a","name":"A","statement":"A holds.","aliases":[],"createdAt":"x","provenance":[{"chatId":"chat_1","messageId":"m1"}]},
		    {"id":"n_b","name":"B","statement":"B holds.","aliases":[],"createdAt":"x","provenance":[{"chatId":"src_1","messageId":""}]},
		    {"id":"arg_1","name":"⟹","statement":"A ∧ B ⟹ C","aliases":[],"createdAt":"x","provenance":[]}
		  ],
		  "propositions": [
		    {"id":"n_a","name":"A","statement":"A holds.","aliases":[],"createdAt":"x","provenance":[{"chatId":"chat_1","messageId":"m1"}]}
		  ],
		  "edges": [{"from":"n_a","to":"arg_1"}],
		  "logicalEdges": [],
		  "impLinks": [],
		  "chains": [{"id":"arg_1","premises":["n_a","n_b"],"conclusion":"n_c","provenance":[],"createdAt":"x"}],
		  "sessions": {"chat_1":"Planets"},
		  "fileSources": {"src_1":"notes/kepler.md"},
		  "nodeSessions": {},
		  "clusters": [{"id":"chat_1","label":null,"members":["n_a"]}],
		  "positions": {"n_a":{"x":1.5,"y":-2},"arg_1":{"x":0,"y":0}}
		}
		"""#
		let snapshot = try JSONDecoder().decode(GraphSnapshot.self, from: Data(json.utf8))
		#expect(snapshot.nodes.count == 3)
		#expect(snapshot.edges == [GraphEdge(from: "n_a", to: "arg_1")])
		#expect(snapshot.chains.first?.premises == ["n_a", "n_b"])
		#expect(snapshot.clusters.first?.label == nil)
		#expect(snapshot.positions["n_a"] == GraphPosition(x: 1.5, y: -2))
		#expect(GraphSnapshot.isImplication("arg_1"))
		#expect(!GraphSnapshot.isImplication("n_a"))
		#expect(snapshot.sourceLabel("chat_1") == "Planets")
		#expect(snapshot.sourceLabel("src_1") == "kepler")
		#expect(snapshot.sourceLabel("gone") == nil)
	}

	@Test func renderSettingsFallBackToDefaults() throws {
		let partial = try JSONDecoder().decode(GraphRenderSettings.self, from: Data(#"{"nodeSize":3,"regions":{"blur":10}}"#.utf8))
		#expect(partial.nodeSize == 3)
		#expect(partial.labelZoom == 0.5)
		#expect(partial.regions.blur == 10)
		#expect(partial.regions.dilation == 20)
	}

	@Test func sourceActionsEncodeTheServerVocabulary() throws {
		func encoded(_ action: SourceAction) throws -> [String: JSONValue] {
			try JSONDecoder().decode([String: JSONValue].self, from: JSONEncoder().encode(action))
		}
		#expect(try encoded(.createFolder(name: "Physics", parentId: nil)) == ["action": .string("create-folder"), "name": .string("Physics"), "parentId": .null])
		#expect(try encoded(.moveSource(id: "s", parentId: "f")) == ["action": .string("move"), "id": .string("s"), "kind": .string("source"), "parentId": .string("f")])
		#expect(try encoded(.moveFolder(id: "f", parentId: nil)) == ["action": .string("move"), "id": .string("f"), "kind": .string("folder"), "parentId": .null])
		#expect(try encoded(.renameSource(id: "s", name: "New")) == ["action": .string("rename-source"), "id": .string("s"), "name": .string("New")])
		#expect(try encoded(.deleteFolder(id: "f")) == ["action": .string("delete-folder"), "id": .string("f")])
	}

	@Test func notesFileNameIsTheLastPathSegment() {
		#expect(NotesFile(path: "Notes/physics/kepler.md", data: Data()).name == "kepler.md")
		#expect(NotesFile(path: "kepler.md", data: Data()).name == "kepler.md")
	}
}
