import SwiftUI

/// The mic: starts dictation into its field; while that run is live it
/// becomes the stop button.
struct MicButton: View {
	@Binding var text: String
	@Environment(AppModel.self) private var app
	@State private var id = UUID()

	var body: some View {
		if let dictation = app.dictation {
			let mine = dictation.targetID == id
			Button {
				if mine {
					dictation.stop()
				} else {
					dictation.start(target: id, text: text) { text = $0 }
				}
			} label: {
				if mine, case .preparing = dictation.phase {
					ProgressView().frame(width: 32, height: 32)
				} else {
					Image(systemName: mine ? "stop.circle.fill" : "mic")
						.font(.title3)
						.frame(width: 32, height: 32)
				}
			}
			.tint(mine ? .red : nil)
			.disabled((dictation.isActive && !mine) || dictation.phase == .stopping)
			.accessibilityLabel(mine ? "Stop dictation" : "Dictate")
			.onDisappear {
				dictation.cancel(ifTarget: id)
				dictation.clearError(ifFrom: id)
			}
		}
	}
}

/// Above the dock: the level meter while listening, progress while starting
/// or finishing, and the last failure.
struct DictationStatusRow: View {
	@Environment(AppModel.self) private var app

	var body: some View {
		if let dictation = app.dictation, dictation.isActive || dictation.error != nil {
			HStack(spacing: 8) {
				switch dictation.phase {
				case .preparing(let note):
					ProgressView().controlSize(.small)
					Text(note ?? "Starting dictation…")
				case .recording:
					Circle().fill(.red).frame(width: 7, height: 7)
					Text("LISTENING").fontWeight(.medium).tracking(0.6)
					LevelBars(levels: dictation.levels)
				case .stopping:
					ProgressView().controlSize(.small)
					Text("Finishing dictation…")
				case .idle:
					Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
					Text(dictation.error ?? "")
					Spacer(minLength: 0)
					Button("Dismiss") { dictation.clearError() }.buttonStyle(.borderless)
				}
			}
			.font(.caption)
			.foregroundStyle(.secondary)
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(.horizontal, 14)
			.padding(.top, 8)
		}
	}
}

private struct LevelBars: View {
	let levels: [Float]

	var body: some View {
		HStack(alignment: .center, spacing: 2) {
			ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
				Capsule()
					.fill(Color.accentColor.opacity(0.75))
					.frame(width: 3, height: 3 + CGFloat(level) * 15)
			}
		}
		.frame(height: 18)
		.animation(.linear(duration: 0.06), value: levels)
		.accessibilityHidden(true)
	}
}
