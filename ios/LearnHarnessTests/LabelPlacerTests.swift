import CoreGraphics
import Testing
@testable import LearnHarness

@Suite("Graph label placement")
struct LabelPlacerTests {
	@Test func keepsLabelsThatDoNotTouch() {
		var placer = LabelPlacer()
		let placed1 = placer.place(CGRect(x: 0, y: 0, width: 50, height: 14))
		#expect(placed1)
		let placed2 = placer.place(CGRect(x: 60, y: 0, width: 50, height: 14))
		#expect(placed2)
		let placed3 = placer.place(CGRect(x: 0, y: 30, width: 50, height: 14))
		#expect(placed3)
	}

	@Test func skipsALabelOverAnEarlierOne() {
		var placer = LabelPlacer()
		let placed4 = placer.place(CGRect(x: 0, y: 0, width: 50, height: 14))
		#expect(placed4)
		let placed5 = placer.place(CGRect(x: 20, y: 5, width: 50, height: 14))
		#expect(!placed5)
		#expect(placer.placed.count == 1)
	}

	@Test func theGapCounts() {
		var placer = LabelPlacer(gap: 4)
		let placed6 = placer.place(CGRect(x: 0, y: 0, width: 50, height: 14))
		#expect(placed6)
		// 2 pt apart: inside the 4 pt gap.
		let placed7 = placer.place(CGRect(x: 52, y: 0, width: 50, height: 14))
		#expect(!placed7)
		let placed8 = placer.place(CGRect(x: 55, y: 0, width: 50, height: 14))
		#expect(placed8)
	}

	@Test func theFirstOfferedWins() {
		let busy = CGRect(x: 0, y: 0, width: 80, height: 14)
		let quiet = CGRect(x: 40, y: 0, width: 80, height: 14)
		var placer = LabelPlacer()
		let placed9 = placer.place(busy)
		#expect(placed9)
		let placed10 = placer.place(quiet)
		#expect(!placed10)
		var reversed = LabelPlacer()
		let placed11 = reversed.place(quiet)
		#expect(placed11)
		let placed12 = reversed.place(busy)
		#expect(!placed12)
	}

	@Test func clampKeepsALabelOnScreen() {
		let bounds = CGRect(x: 8, y: 8, width: 300, height: 500)
		let right = LabelPlacer.clamp(CGRect(x: 280, y: 100, width: 80, height: 20), into: bounds)
		#expect(right == CGRect(x: 228, y: 100, width: 80, height: 20))
		let topLeft = LabelPlacer.clamp(CGRect(x: -30, y: -5, width: 80, height: 20), into: bounds)
		#expect(topLeft == CGRect(x: 8, y: 8, width: 80, height: 20))
		let inside = CGRect(x: 50, y: 50, width: 80, height: 20)
		#expect(LabelPlacer.clamp(inside, into: bounds) == inside)
	}
}
