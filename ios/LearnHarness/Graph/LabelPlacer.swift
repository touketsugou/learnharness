import CoreGraphics

/// Keeps the graph's labels from piling up: labels are offered in priority
/// order, and one that would overlap a label already placed (with a gap) is
/// skipped. Zooming in spreads the nodes apart, so more labels fit.
struct LabelPlacer {
	/// Space kept clear between two labels, in points.
	var gap: CGFloat = 4
	private(set) var placed: [CGRect] = []

	init(gap: CGFloat = 4) { self.gap = gap }

	/// Places `rect` unless it overlaps one already placed; true if placed.
	mutating func place(_ rect: CGRect) -> Bool {
		let padded = rect.insetBy(dx: -gap / 2, dy: -gap / 2)
		guard !placed.contains(where: { $0.intersects(padded) }) else { return false }
		placed.append(padded)
		return true
	}

	/// `rect` moved, not resized, to lie within `bounds` (top-left pinned
	/// when it is larger than `bounds`).
	static func clamp(_ rect: CGRect, into bounds: CGRect) -> CGRect {
		var moved = rect
		moved.origin.x = max(bounds.minX, min(rect.minX, bounds.maxX - rect.width))
		moved.origin.y = max(bounds.minY, min(rect.minY, bounds.maxY - rect.height))
		return moved
	}
}
