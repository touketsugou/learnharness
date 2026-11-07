import LHAPI
import SwiftUI

/// The graph section: extraction (the data channel), rendering (display
/// only: off makes the Graph tab show chains & sources) and the extraction
/// chunk budget.
struct GraphSettingsView: View {
	let model: SettingsModel
	@State private var text = ""
	@FocusState private var focused: Bool

	private var graph: [String: JSONValue] { model.section("graph") }
	private var storedBudget: Int? { graph["extractionChunkTokens"]?.intValue }

	var body: some View {
		List {
			Section {
				Toggle(isOn: binding("enabled")) {
					SettingLabel(title: "Extraction", hint: "Off = the graph stops growing")
				}
				Toggle(isOn: binding("rendering")) {
					SettingLabel(title: "Graph rendering", hint: "Off = the Graph tab shows the chains view")
				}
			}
			Section {
				LabeledContent("Extraction chunk budget") {
					TextField(String(SettingsDefaults.extractionChunkTokens), text: $text)
						.keyboardType(.numberPad)
						.multilineTextAlignment(.trailing)
						.focused($focused)
						.onSubmit(commit)
				}
			} footer: {
				Text(verbatim: "\(storedBudget ?? SettingsDefaults.extractionChunkTokens) tok")
			}
		}
		.navigationTitle("Graph")
		.refreshable { await model.load() }
		.onAppear { text = storedBudget.map(String.init) ?? "" }
		.onChange(of: storedBudget) { if !focused { text = storedBudget.map(String.init) ?? "" } }
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

	/// Compose, never drop the sibling fields.
	private func binding(_ key: String) -> Binding<Bool> {
		Binding(get: { graph[key]?.boolValue ?? true }, set: { on in
			var next = graph
			next[key] = .bool(on)
			Task { await model.write("graph", next) }
		})
	}

	/// Empty = factory default; floor only, no ceiling (the server's sanitize).
	private func commit() {
		var next = graph
		switch TokenInput.parse(text, floor: SettingsDefaults.extractionChunkTokensFloor) {
		case .unset:
			guard storedBudget != nil else { return }
			next["extractionChunkTokens"] = nil
		case .value(let value):
			guard value != storedBudget else { text = String(value); return }
			next["extractionChunkTokens"] = .number(Double(value))
			text = String(value)
		case .invalid:
			text = storedBudget.map(String.init) ?? ""
			return
		}
		Task { await model.write("graph", next) }
	}
}
