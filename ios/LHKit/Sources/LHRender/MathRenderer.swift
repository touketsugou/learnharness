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
		let rendered = Self.typeset(LaTeXCompat.rewrite(latex), fontSize: fontSize, color: color, display: display)
		cache[key] = rendered
		return rendered
	}

	/// SwiftMath's `MathImage.asImage()` (left-aligned, no insets), with
	/// `MathAtomFix` applied between parsing and typesetting.
	static func typeset(_ latex: String, fontSize: CGFloat, color: UIColor, display: Bool) -> Rendered? {
		var error: NSError?
		guard let mathList = MTMathListBuilder.build(fromString: latex, error: &error), error == nil else { return nil }
		MathAtomFix.apply(mathList)

		let label = MTMathUILabel()
		label.font = MathFont.latinModernFont.mtfont(size: fontSize)
		label.fontSize = fontSize // also read by the vertical centering in layout
		label.textColor = color
		label.labelMode = display ? .display : .text
		label.textAlignment = .left
		label.mathList = mathList
		let content = label.intrinsicContentSize
		let size = CGSize(width: ceil(content.width), height: ceil(content.height))
		// Laying out in the image's bounds positions the display list as MathImage does.
		label.frame = CGRect(origin: .zero, size: size)
		label.layoutSubviews()
		guard let displayList = label.displayList else { return nil }

		let image = UIGraphicsImageRenderer(size: size).image { context in
			context.cgContext.translateBy(x: 0, y: size.height)
			context.cgContext.scaleBy(x: 1, y: -1)
			displayList.draw(context.cgContext)
		}
		return Rendered(image: image, ascent: displayList.ascent, descent: displayList.descent)
	}
}
