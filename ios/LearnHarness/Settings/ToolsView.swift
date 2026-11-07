import LHAPI
import SwiftUI

/// The agent's tools (web Agent → Tools): graph tools, the quizzing
/// mechanic, the tool switches, the search engine and file access. Every
/// change writes the whole agent section.
struct ToolsView: View {
	let model: SettingsModel
	@State private var folderInput = ""
	@State private var folderError: String?

	private var agent: [String: JSONValue] { model.section("agent") }

	var body: some View {
		List {
			let graphOn = model.section("graph")["enabled"]?.boolValue ?? true
			Section {
				Toggle(isOn: binding(agent["graphTools"]?["enabled"]?.boolValue ?? true) { AgentCompose.graphTools(agent, on: $0) }) {
					SettingLabel(title: "Graph tools", hint: graphOn ? "Lets the tutor consult your knowledge map between sessions" : "Graph is disabled")
				}
				.disabled(!graphOn)
				VStack(alignment: .leading, spacing: 8) {
					SettingLabel(title: "Quizzing", hint: "How both tutors check your understanding")
					Picker("Quizzing", selection: binding(agent["tools"]?["explain"]?.boolValue == true) { AgentCompose.quizMechanics(agent, freeRecall: $0) }) {
						Text("Multiple choice").tag(false)
						Text("Free recall").tag(true)
					}
					.pickerStyle(.segmented)
					.labelsHidden()
				}
				ForEach(toggleableTools, id: \.self) { id in
					Toggle("Tool · \(id)", isOn: binding(agent["tools"]?[id]?.boolValue ?? true) { AgentCompose.tool(agent, id, on: $0) })
				}
			}
			searchSection
			fileAccessSection
		}
		.navigationTitle("Tools")
		.refreshable { await model.load() }
		.task {
			await model.reloadSearch()
			if model.keys == nil { await model.reloadKeys() }
		}
	}

	// MARK: Search engine

	@ViewBuilder private var searchSection: some View {
		let engine = agent["search"]?["engine"]?.stringValue
		let present = Set(model.keys?.keys.filter(\.present).map(\.id) ?? [])
		let anyKey = SearchEngine.all.contains { present.contains($0.envVar) }
		Section {
			Menu {
				Button {
					write(AgentCompose.searchEngine(agent, nil))
				} label: {
					if engine == nil { Label("Automatic", systemImage: "checkmark") } else { Text("Automatic") }
				}
				ForEach(SearchEngine.all) { option in
					Button {
						write(AgentCompose.searchEngine(agent, option.id))
					} label: {
						if engine == option.id { Label(option.label, systemImage: "checkmark") } else { Text(option.label) }
						Text(present.contains(option.envVar) ? "key" : "no key")
					}
				}
			} label: {
				LabeledContent("Search engine", value: SearchEngine.all.first { $0.id == engine }?.label ?? "Automatic")
			}
			.tint(.primary)
			.disabled(!anyKey)
			.opacity(anyKey ? 1 : 0.4)
		} footer: {
			if let reason = model.search?.reason { Text(reason) }
		}
	}

	// MARK: File access

	@ViewBuilder private var fileAccessSection: some View {
		let folders = AgentCompose.folders(agent)
		let accessError = model.fileAccessError
		let restricted = accessError != nil || AgentCompose.restricted(agent)
		// A configuration error forces restriction (the web's effectiveAgent).
		let effective = accessError != nil ? AgentCompose.fileRestriction(agent, restricted: true) : agent
		Section {
			Toggle("Restrict to listed folders", isOn: Binding(get: { restricted }, set: { write(AgentCompose.fileRestriction(effective, restricted: $0)) }))
			ForEach(folders, id: \.self) { folder in
				Text(folder).font(.footnote.monospaced())
					.swipeActions {
						Button("Remove", role: .destructive) { write(AgentCompose.removeFolder(effective, folder)) }
					}
			}
			HStack {
				TextField("Absolute path or ~/folder", text: $folderInput)
					.textInputAutocapitalization(.never)
					.autocorrectionDisabled()
					.font(.footnote.monospaced())
					.onSubmit { addFolder(effective, folders: folders) }
					.onChange(of: folderInput) { folderError = nil }
				Button("Add") { addFolder(effective, folders: folders) }
					.disabled(folderInput.trimmingCharacters(in: .whitespaces).isEmpty)
			}
		} header: {
			Text("File access")
		} footer: {
			VStack(alignment: .leading, spacing: 4) {
				if let folderError { Text(folderError).foregroundStyle(.red) }
				if let accessError { Text(accessError).foregroundStyle(.red) }
				Text(!restricted ? "Broad local source access, except protected locations"
					: folders.isEmpty ? "Restricted: no folders allowed. Add a folder to enable access." : "Only listed folders and subfolders.")
			}
		}
	}

	private func addFolder(_ effective: [String: JSONValue], folders: [String]) {
		let entry = folderInput.trimmingCharacters(in: .whitespacesAndNewlines)
		guard isFileAccessFolder(entry) else {
			folderError = "Enter an absolute path or ~/folder."
			return
		}
		if !folders.contains(entry) { write(AgentCompose.addFolder(effective, entry)) }
		folderInput = ""
		folderError = nil
	}

	// MARK: Writes

	private func binding<Value>(_ value: Value, compose: @escaping (Value) -> [String: JSONValue]) -> Binding<Value> {
		Binding(get: { value }, set: { write(compose($0)) })
	}

	private func write(_ next: [String: JSONValue]) {
		Task { await model.write("agent", next) }
	}
}
