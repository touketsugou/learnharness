import SwiftUI
import UIKit

/// Lets a swipe on a dock's scrolling content resize the dock first, like a
/// sheet: up grows it until it can grow no more, then the content scrolls;
/// down scrolls the content back to its top, then shrinks the dock.
///
/// SwiftUI's ScrollView has no hook for this, so the link joins the backing
/// UIScrollView's own pan: it runs after the scroll view has moved for each
/// step and, when the dock takes the step, puts the content back.
@MainActor final class DockScrollLink: NSObject {
	/// Set on each update by `ScrollViewFinder`, so they read the dock's
	/// current sizes.
	var begin: () -> Void = {}
	/// Offers `dy` (finger movement, down positive) to the dock; true if the
	/// dock resized by it. `atTop`: the content is scrolled to its top.
	var resize: (_ dy: CGFloat, _ atTop: Bool) -> Bool = { _, _ in false }
	var end: (_ resized: Bool) -> Void = { _ in }

	private weak var scrollView: UIScrollView?
	private var lastTranslation: CGFloat = 0
	private var lastOffset: CGPoint = .zero
	/// The latest step resized the dock (no momentum then), and any step did.
	private var lastResized = false
	private var anyResized = false

	func attach(_ view: UIScrollView) {
		guard view !== scrollView else { return }
		scrollView?.panGestureRecognizer.removeTarget(self, action: #selector(pan(_:)))
		scrollView = view
		view.panGestureRecognizer.addTarget(self, action: #selector(pan(_:)))
	}

	@objc private func pan(_ gesture: UIPanGestureRecognizer) {
		guard let scrollView else { return }
		let top = -scrollView.adjustedContentInset.top
		// In window coordinates: the dock moves under the finger as it resizes.
		let translation = gesture.translation(in: nil).y
		switch gesture.state {
		case .began:
			lastTranslation = translation
			lastOffset = scrollView.contentOffset
			lastResized = false
			anyResized = false
			begin()
		case .changed:
			let dy = translation - lastTranslation
			lastTranslation = translation
			guard dy != 0 else { return }
			if resize(dy, lastOffset.y <= top + 0.5) {
				// Undo this step's scroll, and any pull past the top.
				scrollView.contentOffset = CGPoint(x: lastOffset.x, y: max(lastOffset.y, top))
				lastResized = true
				anyResized = true
			} else {
				lastResized = false
			}
			lastOffset = scrollView.contentOffset
		case .ended, .cancelled, .failed:
			if lastResized {
				// A swipe that ended resizing leaves the content still.
				scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: max(scrollView.contentOffset.y, top)), animated: false)
			}
			end(anyResized)
		default:
			break
		}
	}
}

/// Finds the enclosing scroll view for a `DockScrollLink`; place it as the
/// scroll view's content background.
struct ScrollViewFinder: UIViewRepresentable {
	let link: DockScrollLink
	let begin: () -> Void
	let resize: (_ dy: CGFloat, _ atTop: Bool) -> Bool
	let end: (_ resized: Bool) -> Void

	func makeUIView(context: Context) -> FinderView {
		let view = FinderView()
		view.isUserInteractionEnabled = false
		view.link = link
		return view
	}

	func updateUIView(_ view: FinderView, context: Context) {
		view.link = link
		link.begin = begin
		link.resize = resize
		link.end = end
	}

	final class FinderView: UIView {
		var link: DockScrollLink?

		override func didMoveToWindow() {
			super.didMoveToWindow()
			var ancestor = superview
			while let view = ancestor {
				if let scrollView = view as? UIScrollView {
					link?.attach(scrollView)
					return
				}
				ancestor = view.superview
			}
		}
	}
}
