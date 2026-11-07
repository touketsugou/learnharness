import LHAPI
import SwiftUI

/// The read-only knowledge-graph canvas (web graph-canvas.ts, one draw pass
/// per frame): soft cluster regions → arrows → nodes → node labels → the
/// selection → cluster labels. Pinch zooms, drag pans, tap selects.
struct GraphCanvasView: View {
	typealias Point = GraphGeometry.Point

	let scene: GraphScene
	let settings: GraphRenderSettings
	let selectedID: String?
	@Binding var camera: GraphGeometry.Camera?
	/// Fit or focus requests from the screen (each new value acts once).
	let request: CameraRequest
	let onSelect: (String?) -> Void

	@Environment(\.colorScheme) private var colorScheme
	@State private var size: CGSize = .zero
	@State private var lastTranslation: CGSize = .zero
	@State private var lastMagnification: CGFloat = 1
	/// A pinch is in progress: the one-finger drag must not pan meanwhile.
	@State private var pinching = false

	/// Web PICKING_PAD, widened for touch.
	private static let pickPad = 16.0
	/// Phone minimums over the web's world-unit sizes (screen points).
	static let minNodeRadius = 2.5
	static let minArrowHead = 5.0
	static let minLabelFont = 11.0

	/// On-screen node radius at zoom k.
	private func nodeRadius(_ k: Double) -> Double { max(settings.nodeSize * k, Self.minNodeRadius) }

	var body: some View {
		Canvas { context, _ in
			guard let camera else { return }
			draw(&context, camera: camera)
		}
		.background(Color(uiColor: .systemBackground))
		.contentShape(Rectangle())
		.gesture(pan.simultaneously(with: zoom))
		.gesture(doubleTap.exclusively(before: tap))
		.onGeometryChange(for: CGSize.self, of: \.size) { newSize in
			size = newSize
			if camera == nil { fit(scene.allBox) }
		}
		.onChange(of: request) { _, request in
			switch request.target {
			case .fit: fit(scene.visibleBox ?? scene.allBox)
			case .focus(let id): focus(on: id)
			case .none: break
			}
		}
		.onChange(of: scene.allBox) { if camera == nil { fit(scene.allBox) } }
		.accessibilityLabel("Knowledge graph")
	}

	/// The label gate's 1× reference: the zoom that fits the whole graph.
	private var fitK: Double {
		guard let box = scene.allBox, size.width > 10, size.height > 10 else { return 1 }
		return GraphGeometry.fit(box, width: size.width, height: size.height).k
	}

	private func fit(_ box: GraphGeometry.Box?) {
		guard let box, size.width > 10, size.height > 10 else { return }
		var target = GraphGeometry.fit(box, width: size.width, height: size.height)
		target.k = min(target.k, fitK * 8)
		let center = Point(x: (box.minX + box.maxX) / 2, y: (box.minY + box.maxY) / 2)
		target.x = size.width / 2 - center.x * target.k
		target.y = size.height / 2 - center.y * target.k
		withAnimation(.easeOut(duration: 0.25)) { camera = target }
	}

	/// Center a node, zooming in far enough to read labels.
	private func focus(on id: String) {
		guard let node = scene.nodes.first(where: { $0.id == id }), var target = camera, size.width > 10 else { return }
		// Zoom in past the label gate if needed (labels show at ratio ≤ labelZoom).
		let readable = fitK / max(settings.labelZoom, 0.05) * 1.25
		target.k = max(target.k, min(readable, fitK * 60))
		target.x = size.width / 2 - node.point.x * target.k
		target.y = size.height * 0.3 - node.point.y * target.k
		withAnimation(.easeOut(duration: 0.3)) { camera = target }
	}

	private func clamped(_ next: GraphGeometry.Camera, from current: GraphGeometry.Camera, anchor: Point) -> GraphGeometry.Camera {
		let k = min(max(next.k, fitK * 0.25), fitK * 60)
		return k == next.k ? next : current.zoomed(by: k / current.k, around: anchor)
	}

	// MARK: Gestures

	private var pan: some Gesture {
		DragGesture(minimumDistance: 2)
			.onChanged { value in
				guard !pinching else {
					lastTranslation = value.translation
					return
				}
				guard var current = camera else { return }
				current.x += value.translation.width - lastTranslation.width
				current.y += value.translation.height - lastTranslation.height
				lastTranslation = value.translation
				camera = current
			}
			.onEnded { _ in lastTranslation = .zero }
	}

	private var zoom: some Gesture {
		MagnifyGesture()
			.onChanged { value in
				pinching = true
				guard let current = camera else { return }
				let factor = value.magnification / lastMagnification
				lastMagnification = value.magnification
				let anchor = Point(x: value.startLocation.x, y: value.startLocation.y)
				camera = clamped(current.zoomed(by: factor, around: anchor), from: current, anchor: anchor)
			}
			.onEnded { _ in
				lastMagnification = 1
				pinching = false
			}
	}

	private var doubleTap: some Gesture {
		SpatialTapGesture(count: 2).onEnded { value in
			guard let current = camera else { return }
			let anchor = Point(x: value.location.x, y: value.location.y)
			withAnimation(.easeOut(duration: 0.25)) {
				camera = clamped(current.zoomed(by: 2, around: anchor), from: current, anchor: anchor)
			}
		}
	}

	private var tap: some Gesture {
		SpatialTapGesture().onEnded { value in
			guard let camera else { return }
			let radius = nodeRadius(camera.k)
			let candidates = scene.nodes.lazy.filter { !$0.isJunction }.map { (id: $0.id, at: camera.screen($0.point)) }
			onSelect(GraphGeometry.nearest(to: Point(x: value.location.x, y: value.location.y), among: candidates, maxDistance: radius + Self.pickPad))
		}
	}

	// MARK: Drawing

	private func draw(_ context: inout GraphicsContext, camera: GraphGeometry.Camera) {
		let k = camera.k
		let ratio = fitK / k
		let nodeAlpha = GraphGeometry.labelAlpha(ratio: ratio, labelZoom: settings.labelZoom)
		let bounds = CGRect(origin: .zero, size: size)
		func screen(_ p: Point) -> CGPoint {
			let s = camera.screen(p)
			return CGPoint(x: s.x, y: s.y)
		}
		let radius = nodeRadius(k)

		// 1. Cluster regions: drawn opaque into a blurred layer, the region
		//    alpha applied once when the layer composites.
		if settings.regions.enabled, !scene.regions.isEmpty {
			var regions = context
			// Light backgrounds wash the tints out: a stronger alpha there.
			regions.opacity = colorScheme == .dark ? settings.regions.edgeAlpha : min(settings.regions.edgeAlpha * 1.75, 1)
			regions.drawLayer { layer in
				layer.addFilter(.blur(radius: min(settings.regions.blur * k, 240)))
				let width = settings.regions.dilation * 2 * k
				for region in scene.regions {
					let color = Self.hsl(region.hue, 0.65, 0.6)
					var strokes = Path()
					for (a, b) in region.segments {
						strokes.move(to: screen(a))
						strokes.addLine(to: screen(b))
					}
					layer.stroke(strokes, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
					var discs = Path()
					let r = settings.regions.dilation * k
					for spot in region.spots {
						let c = screen(spot)
						discs.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
					}
					layer.fill(discs, with: .color(color))
				}
			}
		}

		// 2. Arrows: shafts stroked at a constant screen width, heads filled.
		if settings.edgeWidth > 0 {
			var shafts = Path()
			var heads = Path()
			let head = max(settings.arrowLength * k, Self.minArrowHead)
			for edge in scene.edges {
				let a = screen(edge.from)
				let b = screen(edge.to)
				guard bounds.insetBy(dx: -40, dy: -40).intersects(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x) + 1, height: abs(a.y - b.y) + 1)) else { continue }
				guard let arrow = GraphGeometry.arrow(
					from: Point(x: a.x, y: a.y), to: Point(x: b.x, y: b.y),
					fromRadius: edge.outOfJunction ? 0 : radius, toRadius: edge.intoJunction ? 0 : radius, headLength: head
				) else { continue }
				shafts.move(to: CGPoint(x: arrow.shaftFrom.x, y: arrow.shaftFrom.y))
				if edge.intoJunction {
					shafts.addLine(to: CGPoint(x: arrow.tip.x, y: arrow.tip.y))
				} else {
					shafts.addLine(to: CGPoint(x: arrow.shaftTo.x, y: arrow.shaftTo.y))
					heads.move(to: CGPoint(x: arrow.tip.x, y: arrow.tip.y))
					heads.addLine(to: CGPoint(x: arrow.left.x, y: arrow.left.y))
					heads.addLine(to: CGPoint(x: arrow.right.x, y: arrow.right.y))
					heads.closeSubpath()
				}
			}
			context.stroke(shafts, with: .color(.secondary), style: StrokeStyle(lineWidth: max(settings.edgeWidth, 0.5), lineCap: .round))
			context.fill(heads, with: .color(.secondary))
		}

		// 3. Nodes (junctions are pure geometry: no disc).
		var discs = Path()
		var onScreen: [(GraphScene.Node, CGPoint)] = []
		for node in scene.nodes where !node.isJunction {
			let c = screen(node.point)
			guard bounds.insetBy(dx: -radius - 60, dy: -radius - 60).contains(c) else { continue }
			discs.addEllipse(in: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
			onScreen.append((node, c))
		}
		context.fill(discs, with: .color(.primary))

		// 4. Node labels: one global zoom gate, world-scaled with the graph
		//    (never below the phone minimum).
		let labelFont = max(settings.labelSize * k, Self.minLabelFont)
		if nodeAlpha > 0.01 {
			var labels = context
			labels.opacity = nodeAlpha
			for (node, c) in onScreen where node.id != selectedID {
				drawLabel(node.name, at: c, radius: radius, font: labelFont, k: k, color: .secondary, in: &labels)
			}
		}

		// 5. The selection: a soft halo in the node color, its name at full strength.
		if let selectedID, let (node, c) = onScreen.first(where: { $0.0.id == selectedID }) {
			let outer = radius * 1.7 + 6
			context.fill(
				Path(ellipseIn: CGRect(x: c.x - outer, y: c.y - outer, width: outer * 2, height: outer * 2)),
				with: .radialGradient(Gradient(colors: [Color.accentColor.opacity(0.45), Color.accentColor.opacity(0)]),
									  center: c, startRadius: radius, endRadius: outer)
			)
			context.stroke(Path(ellipseIn: CGRect(x: c.x - radius - 2, y: c.y - radius - 2, width: radius * 2 + 4, height: radius * 2 + 4)),
						   with: .color(.accentColor), lineWidth: 2)
			drawLabel(node.name, at: c, radius: radius + 2, font: max(labelFont, 12), k: k, color: .primary, in: &context)
		}

		// 6. Cluster labels: topmost, a constant screen size, fading in as
		//    node labels fade out.
		let regionAlpha = 1 - nodeAlpha
		if settings.clusterLabels, regionAlpha > 0.01 {
			var labels = context
			labels.opacity = regionAlpha
			let lightness = colorScheme == .dark ? 0.78 : 0.35
			for region in scene.regions {
				guard let label = region.label, !label.isEmpty else { continue }
				let c = screen(region.centroid)
				guard bounds.insetBy(dx: -120, dy: -60).contains(c) else { continue }
				let text = labels.resolve(
					Text(label)
						.font(.system(size: settings.clusterLabelSize, weight: .medium))
						.foregroundStyle(Self.hsl(region.hue, 0.55, lightness).opacity(0.85))
				)
				let measured = text.measure(in: CGSize(width: 220, height: settings.clusterLabelSize * 1.3 * 3))
				labels.draw(text, in: CGRect(x: c.x - measured.width / 2, y: c.y - measured.height / 2, width: measured.width, height: measured.height))
			}
		}
	}

	private func drawLabel(_ name: String, at c: CGPoint, radius: Double, font: Double, k: Double, color: Color, in context: inout GraphicsContext) {
		// The web wraps at 170 units for a 12-unit label: keep that ratio to the font.
		let maxWidth = 170 * font / 12
		let text = context.resolve(
			Text(name).font(.system(size: font, weight: .medium)).foregroundStyle(color)
		)
		let measured = text.measure(in: CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
		let gap = max(2.9 * k, 2)
		context.draw(text, in: CGRect(x: c.x - measured.width / 2, y: c.y + radius + gap, width: measured.width, height: measured.height))
	}

	/// HSL → SwiftUI color (the web's hsla region and label tints).
	static func hsl(_ hue: Double, _ saturation: Double, _ lightness: Double) -> Color {
		let v = lightness + saturation * min(lightness, 1 - lightness)
		let s = v == 0 ? 0 : 2 * (1 - lightness / v)
		return Color(hue: hue / 360, saturation: s, brightness: v)
	}
}

/// A one-shot camera instruction from the screen.
struct CameraRequest: Equatable {
	enum Target: Equatable {
		case none
		case fit
		case focus(String)
	}

	var serial = 0
	var target: Target = .none

	mutating func fit() {
		serial += 1
		target = .fit
	}

	mutating func focus(_ id: String) {
		serial += 1
		target = .focus(id)
	}
}
