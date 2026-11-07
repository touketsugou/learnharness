import LHAPI
import SwiftUI

/// The Settings tab: seven pages. Server is always reachable (signing out
/// must work with the server down); the others need the server.
struct SettingsScreen: View {
	@Environment(AppModel.self) private var app
	@State private var model: SettingsModel?

	var body: some View {
		NavigationStack {
			List {
				Section {
					link("Providers", systemImage: "key") { ProvidersView(model: $0) }
					link("Models", systemImage: "cpu") { ModelsView(model: $0) }
					link("Tools", systemImage: "wrench.and.screwdriver") { ToolsView(model: $0) }
					link("Graph", systemImage: "point.3.connected.trianglepath.dotted") { GraphSettingsView(model: $0) }
					link("Prompts", systemImage: "text.quote") { PromptsView(model: $0) }
				}
				Section {
					NavigationLink { DictationSettingsView() } label: { Label("Dictation", systemImage: "mic") }
					NavigationLink { ServerView() } label: { Label("Server", systemImage: "server.rack") }
				}
			}
			.navigationTitle("Settings")
		}
		.task {
			guard model == nil, let client = app.client else { return }
			let settings = SettingsModel(client: client, app: app)
			model = settings
			settings.start()
		}
	}

	private func link(_ title: String, systemImage: String, @ViewBuilder destination: @escaping (SettingsModel) -> some View) -> some View {
		NavigationLink {
			if let model {
				SettingsPage(model: model) { destination(model) }
			} else {
				ProgressView()
			}
		} label: {
			Label(title, systemImage: systemImage)
		}
	}
}

/// A page that needs the settings record: loading and failure states, and
/// the save-failure alert.
private struct SettingsPage<Content: View>: View {
	let model: SettingsModel
	@ViewBuilder let content: () -> Content

	var body: some View {
		@Bindable var model = model
		Group {
			if model.record != nil {
				content()
			} else if let error = model.loadError {
				ContentUnavailableView {
					Label("Couldn’t load settings", systemImage: "exclamationmark.triangle")
				} description: {
					Text(error)
				} actions: {
					Button("Retry") { Task { await model.load() } }.buttonStyle(.bordered)
				}
			} else {
				ProgressView()
			}
		}
		.alert("Couldn’t save", isPresented: Binding(get: { model.writeError != nil }, set: { if !$0 { model.writeError = nil } })) {
			Button("OK", role: .cancel) {}
		} message: {
			Text(model.writeError ?? "")
		}
	}
}

/// A row's title with the web's small hint line beneath.
struct SettingLabel: View {
	let title: String
	var hint: String?

	var body: some View {
		VStack(alignment: .leading, spacing: 2) {
			Text(title)
			if let hint, !hint.isEmpty {
				Text(hint).font(.footnote).foregroundStyle(.secondary)
			}
		}
	}
}
