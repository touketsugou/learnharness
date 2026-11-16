import Testing
import UIKit
@testable import LHRender

@Suite("Theme")
struct ThemeTests {
	@Test func confidenceRampFollowsTheDesktopStops() {
		#expect(ConfidenceRamp.hex(for: 0) == 0xEF4444)
		#expect(ConfidenceRamp.hex(for: 30) == 0xF97316)
		#expect(ConfidenceRamp.hex(for: 50) == 0xEAB308)
		#expect(ConfidenceRamp.hex(for: 70) == 0x84CC16)
		#expect(ConfidenceRamp.hex(for: 90) == 0x22C55E)
		#expect(ConfidenceRamp.hex(for: 100) == 0x10B981)
	}

	@Test func otherValuesAreAmber() {
		#expect(ConfidenceRamp.hex(for: 42) == 0xEAB308)
		#expect(ConfidenceRamp.hex(for: -1) == 0xEAB308)
	}

	@MainActor @Test func bundledFontsRegister() {
		LHFonts.register()
		LHFonts.register()
		#expect(UIFont(name: "CMUSerif-Bold", size: 12) != nil)
		#expect(UIFont(name: "JetBrainsMono-Regular", size: 12) != nil)
		#expect(UIFont(name: "SourceSans3-Roman", size: 12) != nil)
		#expect(UIFont(name: "SourceSans3-Italic", size: 12) != nil)
	}
}

@Suite("Markdown preview")
struct MarkdownPreviewTests {
	@Test func formulasBecomeEllipses() {
		#expect(MarkdownPreview.oneLine("Find the eigenvalues of $A$ and **an** orthonormal basis.") == "Find the eigenvalues of … and an orthonormal basis.")
	}

	@Test func flattensToOneLine() {
		#expect(MarkdownPreview.oneLine("First line\nsecond line") == "First line second line")
		#expect(MarkdownPreview.oneLine("# Title\n\nBody") == "Title Body")
		#expect(MarkdownPreview.oneLine("See\n\n$$x^2$$\n\nthen") == "See … then")
	}
}
