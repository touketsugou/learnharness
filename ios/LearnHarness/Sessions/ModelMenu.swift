import LHAPI
import SwiftUI

/// The session's own model and thinking level (web ModelControl, chat
/// mode): writes PUT /api/chats/:id/settings; the server clamps the level.
struct ModelMenu: View {
	let model: SessionModel

	var body: some View {
		Menu {
			if let entry = model.effectiveCatalogEntry, !entry.supportedLevels.isEmpty {
				Menu {
					ForEach(entry.supportedLevels, id: \.self) { level in
						Button { Task { await model.pickThinkingLevel(level) } } label: {
							if level == model.effectiveThinkingLevel { Label(level, systemImage: "checkmark") } else { Text(level) }
						}
					}
				} label: {
					Text("Thinking")
					Text(model.effectiveThinkingLevel ?? "—")
				}
			}
			if let catalog = model.catalog, !catalog.models.isEmpty {
				Section("Model") {
					ForEach(providers(catalog), id: \.self) { provider in
						Menu(provider) {
							ForEach(catalog.models.filter { $0.provider == provider }) { entry in
								Button { Task { await model.pickModel(entry) } } label: {
									if isCurrent(entry) { Label(entry.name, systemImage: "checkmark") } else { Text(entry.name) }
								}
							}
						}
					}
				}
			} else {
				Text("No models configured")
			}
		} label: {
			Label(model.effectiveModel.map { prettyModelName($0.id) } ?? "Model", systemImage: "cpu")
		}
		.disabled(model.offline)
	}

	private func providers(_ catalog: ModelCatalog) -> [String] {
		var seen = Set<String>()
		return catalog.models.map(\.provider).filter { seen.insert($0).inserted }
	}

	private func isCurrent(_ entry: ModelCatalogEntry) -> Bool {
		entry.provider == model.effectiveModel?.provider && entry.id == model.effectiveModel?.id
	}
}
