import Foundation

/// The canvas math the web renderer uses (components/graph-canvas.ts), pure
/// and platform-free: camera fit, arrow glyphs, the label zoom gate, cluster
/// hues, search visibility and picking.
public enum GraphGeometry {
	public struct Point: Sendable, Hashable {
		public var x: Double
		public var y: Double

		public init(x: Double, y: Double) {
			self.x = x
			self.y = y
		}
	}

	/// screen = world · k + (x, y).
	public struct Camera: Sendable, Hashable {
		public var k: Double
		public var x: Double
		public var y: Double

		public init(k: Double, x: Double, y: Double) {
			self.k = k
			self.x = x
			self.y = y
		}

		public func screen(_ p: Point) -> Point { Point(x: p.x * k + x, y: p.y * k + y) }
		public func world(_ p: Point) -> Point { Point(x: (p.x - x) / k, y: (p.y - y) / k) }

		/// Zoom by `factor` keeping the screen point `anchor` fixed.
		public func zoomed(by factor: Double, around anchor: Point) -> Camera {
			Camera(k: k * factor, x: anchor.x - (anchor.x - x) * factor, y: anchor.y - (anchor.y - y) * factor)
		}
	}

	public struct Box: Sendable, Hashable {
		public var minX, minY, maxX, maxY: Double

		public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
			self.minX = minX
			self.minY = minY
			self.maxX = maxX
			self.maxY = maxY
		}

		public static func around(_ points: some Sequence<Point>) -> Box? {
			var box: Box?
			for p in points {
				if var b = box {
					b.minX = min(b.minX, p.x); b.maxX = max(b.maxX, p.x)
					b.minY = min(b.minY, p.y); b.maxY = max(b.maxY, p.y)
					box = b
				} else {
					box = Box(minX: p.x, minY: p.y, maxX: p.x, maxY: p.y)
				}
			}
			return box
		}
	}

	/// The camera that fits `box` into `width`×`height` with `padding` (web fitTransform).
	public static func fit(_ box: Box, width: Double, height: Double, padding: Double = 40) -> Camera {
		let bw = max(box.maxX - box.minX, 1e-6)
		let bh = max(box.maxY - box.minY, 1e-6)
		let k = max(min((width - 2 * padding) / bw, (height - 2 * padding) / bh), 1e-6)
		let cx = (box.minX + box.maxX) / 2
		let cy = (box.minY + box.maxY) / 2
		return Camera(k: k, x: width / 2 - cx * k, y: height / 2 - cy * k)
	}

	public struct Arrow: Sendable, Hashable {
		public var shaftFrom: Point
		public var shaftTo: Point
		public var tip: Point
		public var left: Point
		public var right: Point
	}

	/// An arrow a→b clear of both discs; the head is `headLength` long and
	/// 0.8 × as wide (web arrowGeometry). Nil for coincident points.
	public static func arrow(from a: Point, to b: Point, fromRadius: Double, toRadius: Double, headLength: Double) -> Arrow? {
		let dx = b.x - a.x
		let dy = b.y - a.y
		let length = (dx * dx + dy * dy).squareRoot()
		guard length >= 1e-6 else { return nil }
		let ux = dx / length
		let uy = dy / length
		let tip = Point(x: b.x - ux * toRadius, y: b.y - uy * toRadius)
		let base = Point(x: tip.x - ux * headLength, y: tip.y - uy * headLength)
		let half = 0.4 * headLength
		return Arrow(
			shaftFrom: Point(x: a.x + ux * fromRadius, y: a.y + uy * fromRadius),
			shaftTo: base,
			tip: tip,
			left: Point(x: base.x - uy * half, y: base.y + ux * half),
			right: Point(x: base.x + uy * half, y: base.y - ux * half)
		)
	}

	/// The fade span as a share of the gate (web LABELS_FADE_RATIO).
	public static let labelsFadeRatio = 0.5

	/// Node-label opacity at camera ratio kFit/k: 1 at or below labelZoom,
	/// fading to 0 across labelZoom × fade ratio. Cluster labels use 1 − this.
	public static func labelAlpha(ratio: Double, labelZoom: Double) -> Double {
		let span = labelZoom * labelsFadeRatio
		return min(max(1 - (ratio - labelZoom) / span, 0), 1)
	}

	/// Stable hue per cluster id (web clusterHue: h = (h·31 + code) mod 360
	/// over the id's characters, first UTF-16 unit of each).
	public static func clusterHue(_ id: String) -> Double {
		var h = 0
		for scalar in id.unicodeScalars {
			let unit = Int(scalar.utf16.first ?? 0)
			h = (h * 31 + unit) % 360
		}
		return Double(h)
	}

	/// The search predicate: empty query, or the name or statement contains it.
	public static func matches(name: String, statement: String, query: String) -> Bool {
		let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		guard !q.isEmpty else { return true }
		return name.lowercased().contains(q) || statement.lowercased().contains(q)
	}

	/// The nearest candidate within `maxDistance` of `point` (screen space).
	public static func nearest<ID>(to point: Point, among candidates: some Sequence<(id: ID, at: Point)>, maxDistance: Double) -> ID? {
		var best: ID?
		var bestDistance = maxDistance * maxDistance
		for candidate in candidates {
			let dx = candidate.at.x - point.x
			let dy = candidate.at.y - point.y
			let d = dx * dx + dy * dy
			if d <= bestDistance {
				bestDistance = d
				best = candidate.id
			}
		}
		return best
	}
}

/// Where a proposition came up in a session: the transcript message that
/// holds the first prose of the native teacher message (web firstSourceTextParts).
public enum SessionAnchor {
	/// The transcript message and its first prose part for a native message.
	public struct Target: Sendable, Hashable {
		public var messageID: String
		public var partID: String
	}

	public static func target(forNativeMessage messageId: String, in messages: [NativeViewMessage]) -> Target? {
		guard !messageId.isEmpty else { return nil }
		for message in messages where message.role == .assistant {
			for part in message.parts where part.type == "text" {
				guard let id = part.id, !(part.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
					let match = id.wholeMatch(of: /(.*)-t\d+/), String(match.1) == messageId else { continue }
				return Target(messageID: message.id, partID: id)
			}
		}
		return nil
	}

	public static func viewMessageID(forNativeMessage messageId: String, in messages: [NativeViewMessage]) -> String? {
		target(forNativeMessage: messageId, in: messages)?.messageID
	}
}
