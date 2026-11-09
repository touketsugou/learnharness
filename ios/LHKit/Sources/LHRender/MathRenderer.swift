import SwiftMath
import UIKit

/// LaTeX → image with baseline metrics (SwiftMath), cached per appearance.
@MainActor
public final class MathRenderer {
	public static let shared = MathRenderer()

	public struct Rendered {
		public let image: UIImage
		public let ascent: CGFloat
		public let descent: CGFloat
	}

	private struct Key: Hashable {
		let latex: String
		let fontSize: CGFloat
		let dark: Bool
		let display: Bool
	}

	private var cache: [Key: Rendered?] = [:]

	/// nil when SwiftMath cannot typeset the LaTeX (callers show the source).
	public func render(_ latex: String, fontSize: CGFloat, dark: Bool, display: Bool) -> Rendered? {
		let key = Key(latex: latex, fontSize: fontSize, dark: dark, display: display)
		if let hit = cache[key] { return hit }
		if cache.count > 600 { cache.removeAll(keepingCapacity: true) }
		let color = UIColor.label.resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
		_ = LaTeXCompat.registerSymbols
		var math = MathImage(latex: LaTeXCompat.rewrite(latex), fontSize: fontSize, textColor: color, labelMode: display ? .display : .text, textAlignment: .left)
		let (error, image, layout) = math.asImage()
		let rendered: Rendered? = if error == nil, let image, let layout {
			Rendered(image: image, ascent: layout.ascent, descent: layout.descent)
		} else {
			nil
		}
		cache[key] = rendered
		return rendered
	}
}
