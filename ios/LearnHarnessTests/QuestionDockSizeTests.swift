import Foundation
import Testing
@testable import LearnHarness

@Suite("Question dock size")
struct QuestionDockSizeTests {
	@Test func draggingUpGrowsAndDownShrinks() {
		let up = QuestionDockSize.share(0.6, base: 400, drag: -100, minHeight: 200, visibleHeight: 1000)
		#expect(abs(up - 0.5) < 1e-9)
		let down = QuestionDockSize.share(0.6, base: 400, drag: 100, minHeight: 200, visibleHeight: 1000)
		#expect(abs(down - 0.3) < 1e-9)
	}

	@Test func stopsAtTheLeastHeight() {
		let share = QuestionDockSize.share(0.6, base: 400, drag: 500, minHeight: 250, visibleHeight: 1000)
		#expect(abs(share - 0.25) < 1e-9)
	}

	@Test func stopsAtNinetyPercent() {
		let share = QuestionDockSize.share(0.6, base: 600, drag: -900, minHeight: 200, visibleHeight: 1000)
		#expect(abs(share - 0.9) < 1e-9)
	}

	@Test func ninetyPercentWinsOverATallLeast() {
		let share = QuestionDockSize.share(0.6, base: 600, drag: 0, minHeight: 950, visibleHeight: 1000)
		#expect(abs(share - 0.9) < 1e-9)
	}

	@Test func aSwipeUpGrowsTheDockUntilItCannot() {
		#expect(QuestionDockSize.consumes(dy: -5, height: 300, minHeight: 200, maxHeight: 500, atTop: false))
		#expect(!QuestionDockSize.consumes(dy: -5, height: 500, minHeight: 200, maxHeight: 500, atTop: true))
	}

	@Test func aSwipeDownShrinksTheDockOnlyFromTheTop() {
		#expect(QuestionDockSize.consumes(dy: 5, height: 300, minHeight: 200, maxHeight: 500, atTop: true))
		#expect(!QuestionDockSize.consumes(dy: 5, height: 300, minHeight: 200, maxHeight: 500, atTop: false))
		#expect(!QuestionDockSize.consumes(dy: 5, height: 200, minHeight: 200, maxHeight: 500, atTop: true))
	}

	@Test func noMovementIsTheContents() {
		#expect(!QuestionDockSize.consumes(dy: 0, height: 300, minHeight: 200, maxHeight: 500, atTop: true))
	}

	@Test func theCeilingKeepsThePeek() {
		#expect(QuestionDockSize.ceiling(share: 0.6, minHeight: 200, visibleHeight: 1000) == 600)
		// The keyboard leaves 400: 30% would be 120, under the 250 peek.
		#expect(QuestionDockSize.ceiling(share: 0.3, minHeight: 250, visibleHeight: 400) == 250)
		#expect(QuestionDockSize.ceiling(share: 0.3, minHeight: 500, visibleHeight: 400) == 400)
		#expect(QuestionDockSize.ceiling(share: 0.6, minHeight: 200, visibleHeight: nil) == nil)
	}

	@Test func keepsTheShareUntilMeasured() {
		#expect(QuestionDockSize.share(0.7, base: 400, drag: -100, minHeight: 200, visibleHeight: nil) == 0.7)
		#expect(QuestionDockSize.share(0.7, base: 400, drag: -100, minHeight: 200, visibleHeight: 0) == 0.7)
	}
}
