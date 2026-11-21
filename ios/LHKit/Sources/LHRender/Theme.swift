import CoreText
import SwiftUI

/// The app's bundled fonts (OFL, see Resources/Fonts): CMU Serif bold for
/// titles, JetBrains Mono for chrome labels, Source Sans 3 for prose — the
/// desktop's three faces.
public enum LHFonts {
	public static let titleFamily = "CMU Serif"
	public static let monoFamily = "JetBrains Mono"
	public static let proseFamily = "Source Sans 3"

	/// Register the bundled fonts with the process (once; later calls do nothing).
	/// The package's resources live outside the app bundle, where UIAppFonts
	/// can't reach them.
	@MainActor public static func register() {
		guard !registered else { return }
		registered = true
		guard let urls = Bundle.module.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") else { return }
		CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
	}

	@MainActor private static var registered = false
}

/// The desktop's dark palette (app/globals.css).
public enum LHColor {
	public static let bg = Color(hex: 0x141414)
	public static let raised = Color(hex: 0x1C1C1C)
	public static let edge = Color(hex: 0x434343)
	public static let hairline = Color(hex: 0x2E2E2E)
	public static let ink = Color(hex: 0xE6E6E6)
	public static let muted = Color(hex: 0x8D8D8D)
	public static let amber = Color(hex: 0xEAB308)
	public static let success = Color(hex: 0x22C55E)
	public static let error = Color(hex: 0xEF4444)
}

public enum LHFont {
	/// CMU Serif bold, scaling with Dynamic Type like `relativeTo`.
	public static func title(_ size: CGFloat, relativeTo style: Font.TextStyle = .title) -> Font {
		.custom(LHFonts.titleFamily, size: size, relativeTo: style).weight(.bold)
	}

	/// The uppercase chrome label (pair with `.textCase(.uppercase)` and
	/// `LHFont.labelTracking`): JetBrains Mono medium, 11 pt.
	public static func label(_ size: CGFloat = 11) -> Font {
		.custom(LHFonts.monoFamily, size: size, relativeTo: .caption).weight(.medium)
	}

	/// The label's letter spacing: 0.08 em.
	public static func labelTracking(_ size: CGFloat = 11) -> CGFloat { size * 0.08 }

	/// JetBrains Mono at a text style's size (code, inline code).
	public static func mono(_ style: Font.TextStyle) -> Font {
		.custom(LHFonts.monoFamily, size: baseSize(style) * 0.94, relativeTo: style)
	}

	/// Source Sans 3 at a text style's size.
	public static func prose(_ style: Font.TextStyle = .body) -> Font {
		.custom(LHFonts.proseFamily, size: baseSize(style), relativeTo: style)
	}

	/// The style's size at the default Dynamic Type setting (`relativeTo`
	/// scales from there).
	static func baseSize(_ style: Font.TextStyle) -> CGFloat {
		UIFont.preferredFont(forTextStyle: style.uiTextStyle, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)).pointSize
	}
}

/// The confidence rail's six-step ramp (components/confidence-rail.tsx):
/// 0 red → 100 emerald, indexed by stop; any other value is amber.
public enum ConfidenceRamp {
	public static let stops = [0, 30, 50, 70, 90, 100]
	public static let hexes: [UInt32] = [0xEF4444, 0xF97316, 0xEAB308, 0x84CC16, 0x22C55E, 0x10B981]

	public static func hex(for stop: Int) -> UInt32 {
		stops.firstIndex(of: stop).map { hexes[$0] } ?? hexes[2]
	}

	public static func color(for stop: Int) -> Color { Color(hex: hex(for: stop)) }
}

extension Color {
	public init(hex: UInt32) {
		self.init(
			.sRGB,
			red: Double((hex >> 16) & 0xFF) / 255,
			green: Double((hex >> 8) & 0xFF) / 255,
			blue: Double(hex & 0xFF) / 255
		)
	}
}

extension View {
	/// The desktop's uppercase chrome label: JetBrains Mono medium, tracked.
	public func lhLabel(_ size: CGFloat = 11) -> some View {
		font(LHFont.label(size)).tracking(LHFont.labelTracking(size)).textCase(.uppercase)
	}
}

extension View {
	/// A page in the desktop's look: the palette's background behind lists
	/// and forms instead of the system black.
	public func lhScreen() -> some View {
		scrollContentBackground(.hidden).background(LHColor.bg)
	}

	/// List rows in the palette's raised color. A sheet would otherwise
	/// draw them lighter (#2C2C2E); apply to the rows (a Group of them works).
	public func lhRows() -> some View {
		listRowBackground(LHColor.raised)
	}

	/// A sheet in the desktop's look (apply to the sheet's root view).
	public func lhSheet() -> some View {
		presentationBackground(LHColor.bg)
	}
}

extension LHFonts {
	/// UIKit's navigation bars: CMU Serif bold titles in the ink color,
	/// scaling with Dynamic Type. Call once at launch, after `register()`.
	@MainActor public static func styleNavigationBars() {
		func title(_ size: CGFloat, _ style: UIFont.TextStyle) -> UIFont {
			let descriptor = UIFontDescriptor(fontAttributes: [.family: titleFamily])
			return UIFontMetrics(forTextStyle: style).scaledFont(for: UIFont(descriptor: descriptor, size: size))
		}
		let ink = UIColor(red: 0xE6 / 255, green: 0xE6 / 255, blue: 0xE6 / 255, alpha: 1)
		let bar = UINavigationBar.appearance()
		bar.largeTitleTextAttributes = [.font: title(34, .largeTitle), .foregroundColor: ink]
		bar.titleTextAttributes = [.font: title(17, .headline), .foregroundColor: ink]
	}
}
