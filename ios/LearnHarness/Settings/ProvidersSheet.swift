import LHRender
import SwiftUI

/// Settings → Providers as a sheet: where "Add a provider key" leads when
/// the server has no model to offer (the web's zero-keys pill), so the
/// learner adds a key without leaving the session.
struct ProvidersSheet: View {
	@Environment(AppModel.self) private var app
	@Environment(\.dismiss) private var dismiss
	@State private var model: SettingsModel?

	var body: some View {
		NavigationStack {
			Group {
				if let model, model.record != nil {
					ProvidersView(model: model)
				} else if let error = model?.loadError {
					ContentUnavailableView {
						Label("Couldn’t load settings", systemImage: "exclamationmark.triangle")
					} description: {
						Text(error)
					} actions: {
						Button("Retry") { Task { await model?.load() } }.buttonStyle(.bordered)
					}
				} else {
					ProgressView()
				}
			}
			.lhScreen()
			.toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
		}
		.lhSheet()
		.task {
			guard model == nil, let client = app.client else { return }
			let settings = SettingsModel(client: client, app: app)
			model = settings
			settings.start()
		}
		.onDisappear { model?.stop() }
	}
}

/// The zero-keys button: "Add a provider key".
struct AddProviderKeyButton: View {
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			Label("Add a provider key", systemImage: "key")
		}
	}
}
