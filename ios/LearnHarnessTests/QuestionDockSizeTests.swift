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

	@Test func theHoldCatchesOnlyAtTheTopWithContentToFillIt() {
		#expect(QuestionDockHold.holds(height: 900, fitHeight: 900, top: 900))
		#expect(!QuestionDockHold.holds(height: 850, fitHeight: 900, top: 900))
		// A short question stops the dock below the top: nothing holds it.
		#expect(!QuestionDockHold.holds(height: 900, fitHeight: 500, top: 900))
	}

	@Test func aPullGivesAThirdUntilItLetsGo() {
		var pull: CGFloat? = 0
		pull = QuestionDockHold.pull(pull!, step: 30)
		#expect(pull == 30)
		#expect(QuestionDockHold.sag(30) == 10)
		pull = QuestionDockHold.pull(pull!, step: 29)
		#expect(pull == 59)
		#expect(QuestionDockHold.pull(59, step: 1) == nil)
	}

	@Test func pushingBackUpUndoesThePull() {
		#expect(QuestionDockHold.pull(20, step: -15) == 5)
		#expect(QuestionDockHold.pull(20, step: -40) == 0)
	}
}
