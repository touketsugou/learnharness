import Foundation
import Testing
@testable import LHAPI

@Suite("Graph geometry")
struct GraphGeometryTests {
	typealias P = GraphGeometry.Point

	@Test func fitCentersTheBox() {
		let camera = GraphGeometry.fit(.init(minX: 0, minY: 0, maxX: 100, maxY: 50), width: 280, height: 280)
		#expect(camera.k == 2)
		#expect(camera.screen(P(x: 50, y: 25)) == P(x: 140, y: 140))
	}

	@Test func zoomKeepsTheAnchorFixed() {
		let camera = GraphGeometry.Camera(k: 2, x: 10, y: 20)
		let anchor = P(x: 100, y: 80)
		let before = camera.world(anchor)
		let after = camera.zoomed(by: 3, around: anchor).world(anchor)
		#expect(abs(before.x - after.x) < 1e-9 && abs(before.y - after.y) < 1e-9)
	}

	@Test func arrowClearsBothDiscs() throws {
		let arrow = try #require(GraphGeometry.arrow(from: P(x: 0, y: 0), to: P(x: 10, y: 0), fromRadius: 1, toRadius: 2, headLength: 2))
		#expect(arrow.shaftFrom == P(x: 1, y: 0))
		#expect(arrow.tip == P(x: 8, y: 0))
		#expect(arrow.shaftTo == P(x: 6, y: 0))
		#expect(arrow.left == P(x: 6, y: 0.8))
		#expect(arrow.right == P(x: 6, y: -0.8))
		#expect(GraphGeometry.arrow(from: P(x: 1, y: 1), to: P(x: 1, y: 1), fromRadius: 0, toRadius: 0, headLength: 1) == nil)
	}

	@Test func labelGateFades() {
		#expect(GraphGeometry.labelAlpha(ratio: 0.3, labelZoom: 0.5) == 1)
		#expect(GraphGeometry.labelAlpha(ratio: 0.625, labelZoom: 0.5) == 0.5)
		#expect(GraphGeometry.labelAlpha(ratio: 1, labelZoom: 0.5) == 0)
	}

	@Test func hueMatchesTheWebHash() {
		// ((97·31+98) mod 360 = 135; (135·31+99) mod 360 = 234 — as the JS loop computes.
		#expect(GraphGeometry.clusterHue("abc") == 234)
		#expect(GraphGeometry.clusterHue("") == 0)
	}

	@Test func searchMatchesNameOrStatement() {
		#expect(GraphGeometry.matches(name: "Transistor", statement: "A switch.", query: "  "))
		#expect(GraphGeometry.matches(name: "Transistor", statement: "A switch.", query: "SWITCH"))
		#expect(!GraphGeometry.matches(name: "Transistor", statement: "A switch.", query: "gate"))
	}

	@Test func pickingTakesTheNearestWithinReach() {
		let nodes: [(id: String, at: P)] = [("a", P(x: 0, y: 0)), ("b", P(x: 5, y: 0))]
		#expect(GraphGeometry.nearest(to: P(x: 3.5, y: 0), among: nodes, maxDistance: 2) == "b")
		#expect(GraphGeometry.nearest(to: P(x: 20, y: 0), among: nodes, maxDistance: 2) == nil)
	}

	@Test func anchorFindsTheTranscriptMessage() throws {
		let json = #"""
		[{"id":"u1","role":"user","parts":[{"type":"text","text":"hi"}]},
		 {"id":"g1","role":"assistant","parts":[{"type":"text","id":"m7-t0","text":"  "},{"type":"text","id":"m7-t1","text":"Mercury."}]}]
		"""#
		let messages = try JSONDecoder().decode([NativeViewMessage].self, from: Data(json.utf8))
		#expect(SessionAnchor.viewMessageID(forNativeMessage: "m7", in: messages) == "g1")
		#expect(SessionAnchor.target(forNativeMessage: "m7", in: messages)?.partID == "m7-t1")
		#expect(SessionAnchor.viewMessageID(forNativeMessage: "m8", in: messages) == nil)
		#expect(SessionAnchor.viewMessageID(forNativeMessage: "", in: messages) == nil)
	}
}
