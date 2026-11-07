import Foundation
import LHAPI

/// Everything the canvas draws, in world coordinates, rebuilt only when the
/// snapshot or the search changes (never per frame).
struct GraphScene {
	typealias Point = GraphGeometry.Point

	struct Node: Identifiable {
		let id: String
		let name: String
		let point: Point
		/// A multi-premise chain's junction: drawn as pure geometry, never picked.
		let isJunction: Bool
	}

	struct Edge {
		let from: Point
		let to: Point
		/// Into a junction: headless, runs to its center.
		let intoJunction: Bool
		/// Out of a junction: starts at its center.
		let outOfJunction: Bool
	}

	/// One cluster's soft region (web splat): its intra-cluster edges as thick
	/// strokes plus a disc for each member no such edge touches.
	struct Region: Identifiable {
		let id: String
		let hue: Double
		let label: String?
		let centroid: Point
		let segments: [(Point, Point)]
		let spots: [Point]
	}

	let nodes: [Node]
	let edges: [Edge]
	let regions: [Region]
	/// Every positioned node (the camera's fit box, independent of search).
	let allBox: GraphGeometry.Box?
	/// The visible nodes' box.
	let visibleBox: GraphGeometry.Box?
	let totalPropositions: Int

	init(snapshot: GraphSnapshot, query: String) {
		let positions = snapshot.positions
		func point(_ id: String) -> Point? { positions[id].map { Point(x: $0.x, y: $0.y) } }

		var visible = Set<String>()
		var nodes: [Node] = []
		for node in snapshot.nodes {
			guard GraphGeometry.matches(name: node.name, statement: node.statement, query: query), let at = point(node.id) else { continue }
			visible.insert(node.id)
			nodes.append(Node(id: node.id, name: node.name, point: at, isJunction: GraphSnapshot.isImplication(node.id)))
		}
		self.nodes = nodes

		edges = snapshot.edges.compactMap { edge in
			guard visible.contains(edge.from), visible.contains(edge.to), let a = point(edge.from), let b = point(edge.to) else { return nil }
			return Edge(from: a, to: b, intoJunction: GraphSnapshot.isImplication(edge.to), outOfJunction: GraphSnapshot.isImplication(edge.from))
		}

		var clusterOf: [String: Int] = [:]
		for (index, cluster) in snapshot.clusters.enumerated() {
			for member in cluster.members { clusterOf[member] = index }
		}
		var regions: [Region] = []
		for (index, cluster) in snapshot.clusters.enumerated() {
			let members = cluster.members.filter(visible.contains).compactMap { id in point(id).map { (id, $0) } }
			guard !members.isEmpty else { continue }
			var segments: [(Point, Point)] = []
			var touched = Set<String>()
			for edge in snapshot.edges where clusterOf[edge.from] == index && clusterOf[edge.to] == index {
				guard visible.contains(edge.from), visible.contains(edge.to), let a = point(edge.from), let b = point(edge.to) else { continue }
				segments.append((a, b))
				touched.insert(edge.from)
				touched.insert(edge.to)
			}
			let spots = members.filter { !touched.contains($0.0) }.map(\.1)
			let centroid = Point(
				x: members.map(\.1.x).reduce(0, +) / Double(members.count),
				y: members.map(\.1.y).reduce(0, +) / Double(members.count)
			)
			regions.append(Region(id: cluster.id, hue: GraphGeometry.clusterHue(cluster.id), label: cluster.label,
								  centroid: centroid, segments: segments, spots: spots))
		}
		self.regions = regions

		allBox = GraphGeometry.Box.around(snapshot.nodes.compactMap { point($0.id) })
		visibleBox = GraphGeometry.Box.around(nodes.map(\.point))
		totalPropositions = snapshot.propositions.count
	}
}
