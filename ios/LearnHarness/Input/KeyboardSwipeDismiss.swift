import SwiftUI
import UIKit

/// Whether the keyboard is on screen, from UIKit's keyboard notifications.
/// Started at launch (LearnHarnessApp), so it knows of a keyboard that rose
/// before a dock appeared.
@MainActor final class KeyboardState {
	static let shared = KeyboardState()
	private(set) var isVisible = false
	private var observers: [NSObjectProtocol] = []

	func start() {
		guard observers.isEmpty else { return }
		let center = NotificationCenter.default
		observers = [
			center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { _ in
				MainActor.assumeIsolated { KeyboardState.shared.isVisible = true }
			},
			center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { _ in
				MainActor.assumeIsolated { KeyboardState.shared.isVisible = false }
			},
		]
	}

	func dismiss() {
		UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
	}
}

/// What a swipe on a dock means for the keyboard, from how far it has moved
/// (down positive).
enum KeyboardSwipe: Equatable {
	/// Too short to tell.
	case undecided
	/// Down and mostly vertical, far enough: the keyboard goes.
	case dismiss
	/// Up or sideways first: an ordinary swipe.
	case pass

	/// How far a swipe moves before its direction counts.
	static let slop: CGFloat = 4
	/// How far down a swipe moves before the keyboard goes.
	static let distance: CGFloat = 10

	static func decide(dx: CGFloat, dy: CGFloat) -> KeyboardSwipe {
		guard max(abs(dx), abs(dy)) >= slop else { return .undecided }
		guard dy > abs(dx) else { return .pass }
		return dy >= distance ? .dismiss : .undecided
	}
}

extension View {
	/// While the keyboard is up, a swipe down on this view closes it, and
	/// nothing under the finger scrolls for that swipe. A swipe that starts
	/// in a text field with more text than shows scrolls the text instead.
	func swipeDownDismissesKeyboard() -> some View {
		gesture(KeyboardSwipeGesture())
	}
}

private struct KeyboardSwipeGesture: UIGestureRecognizerRepresentable {
	func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

	func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
		let recognizer = UIPanGestureRecognizer()
		recognizer.cancelsTouchesInView = false
		recognizer.delaysTouchesBegan = false
		recognizer.delaysTouchesEnded = false
		recognizer.delegate = context.coordinator
		return recognizer
	}

	func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
		context.coordinator.handle(recognizer)
	}

	@MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
		/// The swipe's first touch, and its scroll views' offsets then.
		private weak var touchView: UIView?
		private var startOffsets: [(view: UIScrollView, offset: CGPoint)] = []
		private var decision: KeyboardSwipe = .undecided

		func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
			guard KeyboardState.shared.isVisible else { return false }
			if let text = Self.ancestor(of: touch.view, as: UITextView.self), text.contentSize.height > text.bounds.height + 0.5 {
				return false
			}
			touchView = touch.view
			return true
		}

		func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
			true
		}

		func handle(_ recognizer: UIPanGestureRecognizer) {
			switch recognizer.state {
			case .began:
				decision = .undecided
				startOffsets = Self.scrollViews(above: touchView).map { ($0, $0.contentOffset) }
				step(recognizer)
			case .changed:
				step(recognizer)
			default:
				decision = .undecided
				startOffsets = []
				touchView = nil
			}
		}

		private func step(_ recognizer: UIPanGestureRecognizer) {
			guard decision == .undecided else { return }
			let translation = recognizer.translation(in: nil)
			decision = KeyboardSwipe.decide(dx: translation.x, dy: translation.y)
			guard decision == .dismiss else { return }
			// Stop the scroll views' own swipe and put back what they moved.
			for (view, offset) in startOffsets where [.began, .changed].contains(view.panGestureRecognizer.state) {
				view.panGestureRecognizer.isEnabled = false
				view.panGestureRecognizer.isEnabled = true
				view.setContentOffset(offset, animated: false)
			}
			KeyboardState.shared.dismiss()
		}

		/// The scroll views the touch is in, a text field's own excepted.
		private static func scrollViews(above view: UIView?) -> [UIScrollView] {
			var found: [UIScrollView] = []
			var next = view
			while let current = next {
				if let scroll = current as? UIScrollView, !(scroll is UITextView) { found.append(scroll) }
				next = current.superview
			}
			return found
		}

		private static func ancestor<T: UIView>(of view: UIView?, as type: T.Type) -> T? {
			var next = view
			while let current = next {
				if let match = current as? T { return match }
				next = current.superview
			}
			return nil
		}
	}
}
