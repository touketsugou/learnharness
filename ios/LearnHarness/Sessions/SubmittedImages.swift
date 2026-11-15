import LHAPI
import SwiftUI

/// Images a learner submitted (a plugin's drawing): small previews, tap for
/// full screen (components/submitted-images.tsx). The view carries each as
/// {type: "image", mimeType, ref}; the bytes load on demand and the session
/// caches them.
struct SubmittedImages: View {
	let model: SessionModel
	let refs: [String]

	/// The refs of a list of image references (anything else is skipped).
	nonisolated static func refs(_ images: JSONValue?) -> [String] {
		(images?.arrayValue ?? []).compactMap { $0["type"]?.stringValue == "image" ? $0["ref"]?.stringValue : nil }
	}

	var body: some View {
		if !refs.isEmpty {
			VStack(alignment: .leading, spacing: 8) {
				ForEach(Array(refs.enumerated()), id: \.offset) { _, ref in
					SubmittedImagePreview(model: model, ref: ref)
				}
			}
		}
	}
}

private struct SubmittedImagePreview: View {
	let model: SessionModel
	let ref: String
	@State private var image: UIImage?
	@State private var failed = false
	@State private var fullScreen = false

	/// About five lines of prose, as the web's preview.
	static let maxHeight: CGFloat = 120

	var body: some View {
		Group {
			if let image {
				Button { fullScreen = true } label: {
					Image(uiImage: image).resizable().scaledToFit()
						.frame(maxWidth: Self.maxHeight * 3, maxHeight: Self.maxHeight, alignment: .leading)
						.clipShape(RoundedRectangle(cornerRadius: 8))
				}
				.buttonStyle(.plain)
				.accessibilityLabel("Submitted image")
				.accessibilityHint("Opens it full screen")
			} else if failed {
				Label("Image unavailable", systemImage: "photo").font(.callout).foregroundStyle(.secondary)
			} else {
				ProgressView().frame(width: Self.maxHeight, height: Self.maxHeight * 0.66)
			}
		}
		.task(id: ref) {
			if let data = await model.submittedImage(ref), let loaded = UIImage(data: data) { image = loaded } else { failed = true }
		}
		.fullScreenCover(isPresented: $fullScreen) {
			if let image { ImageViewer(image: image) }
		}
	}
}

/// One image full screen: pinch or double-tap to zoom, Done to close.
struct ImageViewer: View {
	let image: UIImage
	@Environment(\.dismiss) private var dismiss
	@State private var scale: CGFloat = 1
	@State private var settledScale: CGFloat = 1

	var body: some View {
		NavigationStack {
			GeometryReader { geometry in
				ScrollView([.horizontal, .vertical]) {
					Image(uiImage: image).resizable().scaledToFit()
						.frame(width: geometry.size.width * scale, height: geometry.size.height * scale)
				}
				.scrollIndicators(.hidden)
				.gesture(
					MagnifyGesture()
						.onChanged { scale = min(6, max(1, settledScale * $0.magnification)) }
						.onEnded { _ in settledScale = scale }
				)
				.onTapGesture(count: 2) {
					withAnimation {
						scale = scale > 1 ? 1 : 2.5
						settledScale = scale
					}
				}
			}
			.background(Color.black.ignoresSafeArea())
			.toolbar {
				ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
			}
			.toolbarBackground(.visible, for: .navigationBar)
		}
	}
}
