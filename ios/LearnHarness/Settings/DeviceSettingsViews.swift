import LHAPI
import SwiftUI

/// The dictation engine: a preference stored on this iPhone.
struct DictationSettingsView: View {
	@AppStorage(DictationController.engineKey) private var engine = DictationController.Engine.apple.rawValue

	var body: some View {
		Form {
			Section {
				Picker("Engine", selection: $engine) {
					Text("On this iPhone").tag(DictationController.Engine.apple.rawValue)
					Text("Deepgram").tag(DictationController.Engine.deepgram.rawValue)
				}
				.pickerStyle(.inline)
				.labelsHidden()
			} header: {
				Text("Engine")
			} footer: {
				Text(engine == DictationController.Engine.deepgram.rawValue
					? "Uses the server’s Deepgram key (Providers → Dictation); the transcript is inserted when you stop. Stored on this iPhone."
					: "Apple’s on-device speech recognition with live words. Stored on this iPhone.")
			}
		}
		.navigationTitle("Dictation")
	}
}

/// The server this app talks to, and signing out.
struct ServerView: View {
	@Environment(AppModel.self) private var app
	@State private var confirming = false

	var body: some View {
		Form {
			Section {
				LabeledContent("Address", value: app.serverAddress ?? "—")
			}
			Section {
				Button("Sign Out", role: .destructive) { confirming = true }
			} footer: {
				Text("Removes the access token and this server’s offline copies from this iPhone.")
			}
		}
		.navigationTitle("Server")
		.confirmationDialog("Sign out of this server?", isPresented: $confirming, titleVisibility: .visible) {
			Button("Sign Out", role: .destructive) { Task { await app.signOut() } }
		}
	}
}
