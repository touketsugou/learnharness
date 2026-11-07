import LHAPI
import SwiftUI

/// The three model slots (PUT /api/settings/models), the compaction
/// threshold, and per-slot cache retention. A slot shows its override, else
/// the resolved factory pin; the stored id stays visible even when its
/// provider's key lapsed out of the catalog.
struct ModelsView: View {
	let model: SettingsModel
	@State private var connecting: SubscriptionProvider?

	private static let allLevels = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]

	var body: some View {
		List {
			ForEach(ModelSlot.allCases) { slot in
				Section {
					let state = slotState(slot)
					NavigationLink {
						SlotModelPicker(model: model, slot: slot, current: state.coordinate) { entry in
							let thinking = ThinkingLevels.populate(state.thinking.isEmpty ? nil : state.thinking, supported: entry.supportedLevels)
							Task { await model.write("models", ModelsCompose.slot(model.section("models"), slot, provider: entry.provider, id: entry.id, thinking: thinking)) }
						}
					} label: {
						LabeledContent("Model", value: state.coordinate.map { prettyModelName($0.id) } ?? "—")
					}
					Menu {
						ForEach(state.levels, id: \.self) { level in
							Button {
								Task { await model.write("models", ModelsCompose.slot(model.section("models"), slot, provider: state.provider, id: state.modelId, thinking: level)) }
							} label: {
								if level == state.shownThinking { Label(level, systemImage: "checkmark") } else { Text(level) }
							}
						}
					} label: {
						LabeledContent("Thinking", value: state.shownThinking ?? "—")
					}
					.tint(.primary)
					if slot != .strong, let subscription = SubscriptionProvider.forCatalogProvider(state.coordinate?.provider),
						model.subscription(subscription.providerId).connected, !model.subscription(subscription.providerId).allowBackgroundUse {
						Button("Enable background use") { connecting = subscription }
					}
				} header: {
					Text(slot.label)
				} footer: {
					Text(slot.roster)
				}
			}
			if model.catalog?.models.isEmpty == true {
				Text("No models — add a provider key in Providers").foregroundStyle(.secondary)
			}
			CompactionSection(model: model)
			Section {
				ForEach(ModelSlot.allCases) { slot in
					let override = model.section("models")[slot.rawValue]
					Menu {
						ForEach(CacheRetentionOption.all) { option in
							Button {
								Task { await model.write("models", ModelsCompose.cacheRetention(model.section("models"), slot, option.value)) }
							} label: {
								Text(option.label)
								Text(option.detail)
							}
						}
					} label: {
						LabeledContent(slot.label, value: CacheRetentionOption.option(for: override?["cacheRetention"]?.stringValue).compact)
					}
					.tint(.primary)
					.disabled(override?["model"] == nil)
				}
			} header: {
				Text("Cache retention")
			} footer: {
				Text("Available once a slot has its own model.")
			}
		}
		.navigationTitle("Models")
		.refreshable { await model.load() }
		.task {
			await model.reloadCatalog()
			await model.reloadSubscriptions()
		}
		.sheet(item: $connecting) { provider in
			SubscriptionSheet(model: model, provider: provider)
		}
	}

	private struct SlotState {
		var provider: String
		var modelId: String
		var thinking: String
		var coordinate: ChatModelChoice?
		var levels: [String]
		var shownThinking: String?
	}

	private func slotState(_ slot: ModelSlot) -> SlotState {
		let override = model.section("models")[slot.rawValue]
		let provider = override?["model"]?["provider"]?.stringValue ?? ""
		let modelId = override?["model"]?["id"]?.stringValue ?? ""
		let thinking = override?["thinkingLevel"]?.stringValue ?? ""
		let pin = model.catalog?.slotPin(slot)
		let coordinate = modelId.isEmpty ? pin?.model : ChatModelChoice(provider: provider, id: modelId)
		let chosen = model.catalog?.entry(coordinate?.provider, coordinate?.id)
		let levels = chosen?.supportedLevels ?? Self.allLevels
		let shown = !thinking.isEmpty ? thinking : chosen.map { ThinkingLevels.defaultLevel($0.supportedLevels) }
		return SlotState(provider: provider, modelId: modelId, thinking: thinking, coordinate: coordinate, levels: levels, shownThinking: shown)
	}
}

/// The compaction threshold (its own settings section); empty = default.
private struct CompactionSection: View {
	let model: SettingsModel
	@State private var text = ""
	@FocusState private var focused: Bool

	private var stored: Int? { model.section("compaction")["thresholdTokens"]?.intValue }

	var body: some View {
		Section {
			LabeledContent("Compaction threshold") {
				TextField(String(SettingsDefaults.compactionThresholdTokens), text: $text)
					.keyboardType(.numberPad)
					.multilineTextAlignment(.trailing)
					.focused($focused)
					.onSubmit(commit)
			}
		} header: {
			Text("Context")
		} footer: {
			Text(verbatim: "\(stored ?? SettingsDefaults.compactionThresholdTokens) tok")
		}
		.onAppear { text = stored.map(String.init) ?? "" }
		.onChange(of: stored) { if !focused { text = stored.map(String.init) ?? "" } }
		.onChange(of: focused) { if !focused { commit() } }
		.toolbar {
			if focused {
				ToolbarItemGroup(placement: .keyboard) {
					Spacer()
					Button("Done") { focused = false }
				}
			}
		}
	}

	private func commit() {
		var section = model.section("compaction")
		switch TokenInput.parse(text, floor: SettingsDefaults.compactionThresholdFloor) {
		case .unset:
			guard stored != nil else { return }
			section["thresholdTokens"] = nil
		case .value(let value):
			guard value != stored else { text = String(value); return }
			section["thresholdTokens"] = .number(Double(value))
			text = String(value)
		case .invalid:
			text = stored.map(String.init) ?? ""
			return
		}
		Task { await model.write("compaction", section) }
	}
}

/// Pick a slot's model: searchable, grouped by provider, price on the right.
/// Vision lists image-capable models (plus custom-endpoint ones).
private struct SlotModelPicker: View {
	let model: SettingsModel
	let slot: ModelSlot
	let current: ChatModelChoice?
	let onPick: (ModelCatalogEntry) -> Void
	@Environment(\.dismiss) private var dismiss
	@State private var query = ""

	var body: some View {
		List {
			if let catalog = model.catalog {
				let entries = filtered(catalog.choices(for: slot))
				ForEach(providers(entries), id: \.self) { provider in
					Section(provider) {
						ForEach(entries.filter { $0.provider == provider }) { entry in
							Button {
								onPick(entry)
								dismiss()
							} label: {
								HStack {
									VStack(alignment: .leading, spacing: 2) {
										Text(entry.name)
										if entry.name != entry.id {
											Text(entry.id).font(.caption.monospaced()).foregroundStyle(.secondary)
										}
									}
									Spacer()
									Text(entry.priceLabel).font(.caption).monospacedDigit().foregroundStyle(.secondary)
									if entry.provider == current?.provider, entry.id == current?.id {
										Image(systemName: "checkmark").foregroundStyle(.tint)
									}
								}
							}
							.tint(.primary)
						}
					}
				}
				if catalog.models.isEmpty {
					Text("No models — add a provider key in Providers").foregroundStyle(.secondary)
				} else if entries.isEmpty {
					Text("No models match.").foregroundStyle(.secondary)
				}
			} else {
				ProgressView().frame(maxWidth: .infinity)
			}
		}
		.searchable(text: $query, prompt: "Search models")
		.navigationTitle("\(slot.label) Model")
		.navigationBarTitleDisplayMode(.inline)
	}

	private func filtered(_ entries: [ModelCatalogEntry]) -> [ModelCatalogEntry] {
		let terms = query.lowercased().split(separator: " ")
		guard !terms.isEmpty else { return entries }
		return entries.filter { entry in
			let haystack = "\(entry.provider) \(entry.id) \(entry.name)".lowercased()
			return terms.allSatisfy { haystack.contains($0) }
		}
	}

	private func providers(_ entries: [ModelCatalogEntry]) -> [String] {
		var seen = Set<String>()
		return entries.map(\.provider).filter { seen.insert($0).inserted }
	}
}
