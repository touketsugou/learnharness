import LHAPI
import SwiftUI

/// The sessionless draft (web /chat/new): a session exists only once the
/// first message is sent; that message becomes its title and its opening.
struct NewSessionView: View {
	let onCreated: (String) -> Void
	@Environment(AppModel.self) private var app
	@State private var mode: ChatKind = .teach
	@State private var text = ""
	@State private var picks: [GraphContextPick] = []
	@State private var showPicker = false
	@State private var busy = false
	@State private var error: String?
	@FocusState private var focused: Bool

	var body: some View {
		VStack(spacing: 0) {
			ContentUnavailableView(
				mode == .practice ? "New practice session" : "New session",
				systemImage: mode == .practice ? "pencil.and.list.clipboard" : "sparkles",
				description: Text(mode == .practice
					? "Pick nodes from your knowledge graph, describe what you want to practice, or bring your own problem."
					: "The teacher will open by probing what you already know.")
			)
			VStack(alignment: .leading, spacing: 10) {
				Picker("Session type", selection: $mode) {
					Text("Teach").tag(ChatKind.teach)
					Text("Practice").tag(ChatKind.practice)
				}
				.pickerStyle(.segmented)
				if mode == .practice { pickBar }
				if let error {
					Text(error).font(.callout).foregroundStyle(.red)
				}
				DictationStatusRow().padding(.horizontal, -14)
				HStack(alignment: .bottom, spacing: 6) {
					AttachButton(text: $text)
					TextField(mode == .practice ? "What do you want to practice?" : "What do you want to learn?", text: $text, axis: .vertical)
						.lineLimit(1...8)
						.focused($focused)
						.padding(.horizontal, 12)
						.padding(.vertical, 9)
						.background(RoundedRectangle(cornerRadius: 18).fill(Color(uiColor: .secondarySystemBackground)))
					MicButton(text: $text)
					if busy {
						ProgressView().frame(width: 32, height: 32)
					} else {
						Button { Task { await start() } } label: {
							Image(systemName: "arrow.up.circle.fill").font(.title)
						}
						.accessibilityLabel("Start session")
						.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
					}
				}
			}
			.padding(.horizontal, 14)
			.padding(.vertical, 10)
			.frame(maxWidth: 820)
		}
		.navigationTitle("New session")
		.navigationBarTitleDisplayMode(.inline)
		.sheet(isPresented: $showPicker) {
			if let client = app.client { PracticeMaterialPicker(client: client, picks: $picks) }
		}
		.onAppear { focused = true }
	}

	/// The web pick bar: "Pick nodes", or the count with Clear.
	private var pickBar: some View {
		HStack(spacing: 10) {
			Button { showPicker = true } label: {
				Label(picks.isEmpty ? "Pick nodes" : "\(picks.count) \(picks.count == 1 ? "node" : "nodes") selected",
					  systemImage: "point.3.connected.trianglepath.dotted")
			}
			.buttonStyle(.bordered)
			if !picks.isEmpty {
				Button("Clear", role: .destructive) { picks = [] }
					.buttonStyle(.borderless)
			}
		}
		.controlSize(.small)
	}

	private func start() async {
		await app.dictation?.finish()
		let opening = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !opening.isEmpty, !busy, let client = app.client else { return }
		busy = true
		error = nil
		defer { busy = false }
		// Never create an orphan session the first send would refuse.
		if let catalog = try? await client.modelCatalog(), catalog.defaults == nil {
			error = "No model is set up on the server yet. Choose one in Settings first."
			return
		}
		do {
			let created = try await client.createChat(title: opening, kind: mode, graphContext: mode == .practice ? picks : [])
			app.stashOpening(opening, for: created.id)
			text = ""
			picks = []
			onCreated(created.id)
		} catch {
			self.error = "Couldn’t open the session. Your message is still here. Try sending again."
		}
	}
}

/// Practice material: propositions grouped by the source they came from,
/// each group selectable whole or one proposition at a time.
struct PracticeMaterialPicker: View {
	let client: APIClient
	@Binding var picks: [GraphContextPick]
	@State private var groups: [PracticeMaterial.Group] = []
	@State private var loading = true
	@State private var error: String?
	@State private var search = ""
	@Environment(\.dismiss) private var dismiss

	private var selected: Set<String> { Set(picks.map(\.id)) }

	var body: some View {
		NavigationStack {
			List {
				ForEach(filteredGroups) { group in
					Section {
						ForEach(group.propositions) { proposition in
							PropositionRow(proposition: proposition, isSelected: selected.contains(proposition.id)) {
								toggle(proposition)
							}
						}
					} header: {
						HStack {
							Text(group.label)
							Spacer()
							let all = group.propositions.allSatisfy { selected.contains($0.id) }
							Button(all ? "Deselect all" : "Select all") { setGroup(group, on: !all) }
								.font(.caption)
								.textCase(nil)
						}
					}
				}
			}
			.searchable(text: $search, prompt: "Search propositions")
			.overlay {
				if loading {
					ProgressView()
				} else if let error {
					ContentUnavailableView("Couldn’t load your graph", systemImage: "exclamationmark.triangle", description: Text(error))
				} else if groups.isEmpty {
					ContentUnavailableView("No propositions yet", systemImage: "point.3.connected.trianglepath.dotted",
										   description: Text("Teaching sessions and imported notes add propositions to your knowledge graph."))
				} else if filteredGroups.isEmpty {
					ContentUnavailableView.search(text: search)
				}
			}
			.navigationTitle("Pick nodes")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Clear") { picks = [] }.disabled(picks.isEmpty)
				}
				ToolbarItem(placement: .confirmationAction) {
					Button("Done") { dismiss() }
				}
			}
			.task { await load() }
		}
	}

	private var filteredGroups: [PracticeMaterial.Group] {
		let query = search.trimmingCharacters(in: .whitespaces)
		guard !query.isEmpty else { return groups }
		return groups.compactMap { group in
			if group.label.localizedCaseInsensitiveContains(query) { return group }
			var narrowed = group
			narrowed.propositions = group.propositions.filter {
				$0.name.localizedCaseInsensitiveContains(query) || $0.statement.localizedCaseInsensitiveContains(query)
			}
			return narrowed.propositions.isEmpty ? nil : narrowed
		}
	}

	private func toggle(_ proposition: GraphProposition) {
		if selected.contains(proposition.id) {
			picks.removeAll { $0.id == proposition.id }
		} else {
			picks.append(GraphContextPick(id: proposition.id, name: proposition.name, statement: proposition.statement))
		}
	}

	private func setGroup(_ group: PracticeMaterial.Group, on: Bool) {
		if on {
			let have = selected
			picks += group.propositions.filter { !have.contains($0.id) }
				.map { GraphContextPick(id: $0.id, name: $0.name, statement: $0.statement) }
		} else {
			let ids = Set(group.propositions.map(\.id))
			picks.removeAll { ids.contains($0.id) }
		}
	}

	private func load() async {
		do {
			async let snapshot = client.graphSnapshot()
			async let directory = client.sourceDirectory()
			let graph = try await snapshot
			groups = PracticeMaterial.groups(snapshot: graph, directory: try? await directory)
		} catch {
			self.error = (error as? APIError)?.message ?? error.localizedDescription
		}
		loading = false
	}
}

private struct PropositionRow: View {
	let proposition: GraphProposition
	let isSelected: Bool
	let toggle: () -> Void

	var body: some View {
		Button(action: toggle) {
			HStack(alignment: .firstTextBaseline, spacing: 10) {
				Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
					.foregroundStyle(isSelected ? Color.accentColor : .secondary)
				VStack(alignment: .leading, spacing: 2) {
					Text(proposition.name).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
					Text(proposition.statement).font(.caption).foregroundStyle(.secondary).lineLimit(3)
				}
			}
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.accessibilityAddTraits(isSelected ? .isSelected : [])
	}
}
