import Foundation
import Testing
@testable import LearnHarness

@Suite("Keyboard swipe")
struct KeyboardSwipeTests {
	@Test func aShortMoveIsUndecided() {
		#expect(KeyboardSwipe.decide(dx: 1, dy: 3) == .undecided)
	}

	@Test func downPastTheSlopWaitsForTheDistance() {
		#expect(KeyboardSwipe.decide(dx: 0, dy: 6) == .undecided)
	}

	@Test func downFarEnoughDismisses() {
		#expect(KeyboardSwipe.decide(dx: 0, dy: 10) == .dismiss)
		#expect(KeyboardSwipe.decide(dx: 4, dy: 30) == .dismiss)
	}

	@Test func upPasses() {
		#expect(KeyboardSwipe.decide(dx: 0, dy: -5) == .pass)
	}

	@Test func sidewaysPasses() {
		#expect(KeyboardSwipe.decide(dx: 12, dy: 10) == .pass)
		#expect(KeyboardSwipe.decide(dx: -6, dy: 0) == .pass)
	}
}
