import LHAPI
import LHRender
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
	@Environment(\.horizontalSizeClass) private var sizeClass

	var body: some View {
		VStack(spacing: 0) {
			ScrollView {
				VStack(alignment: .leading, spacing: 22) {
					Text("New session")
						.font(LHFont.title(34, relativeTo: .largeTitle))
						.foregroundStyle(LHColor.ink)
						.accessibilityAddTraits(.isHeader)
					VStack(alignment: .leading, spacing: 10) {
						CardLabel(text: "Session type")
						HStack(alignment: .top, spacing: 10) {
							ModeCard(title: "Teach", systemImage: "sparkles",
									 detail: "Opens by probing what you already know, then plans the steps.",
									 selected: mode == .teach) { mode = .teach }
							ModeCard(title: "Practice", systemImage: "pencil.and.list.clipboard",
									 detail: "Problems from your graph, or bring your own problem.",
									 selected: mode == .practice) { mode = .practice }
						}
					}
					if mode == .practice { material }
				}
				.padding(.horizontal, 16)
				.padding(.top, 8)
				.frame(maxWidth: 820, alignment: .leading)
				.frame(maxWidth: .infinity)
			}
			.scrollDismissesKeyboard(.interactively)
			VStack(alignment: .leading, spacing: 8) {
				if let error {
					Text(error).font(LHFont.prose(.callout)).foregroundStyle(LHColor.error)
				}
				DictationStatusRow().padding(.horizontal, -12)
				HStack(alignment: .bottom, spacing: 8) {
					AttachButton(text: $text).modifier(CircleChrome())
					ComposerField(placeholder: mode == .practice ? "What do you want to practice?" : "What do you want to learn?",
								  text: $text, lines: 1...8, focused: $focused)
					if busy {
						ProgressView().frame(width: 44, height: 44)
					} else {
						SendButton(label: "Start session", enabled: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
							Task { await start() }
						}
					}
				}
			}
			.padding(.horizontal, 12)
			.padding(.vertical, 10)
			.frame(maxWidth: 820)
			.overlay(alignment: .top) { Rectangle().fill(LHColor.hairline).frame(height: 1) }
		}
		.background(LHColor.bg)
		.navigationTitle("")
		.navigationBarTitleDisplayMode(.inline)
		// iPhone: the composer takes the bottom edge, as in a session.
		.toolbar(sizeClass == .compact ? .hidden : .automatic, for: .tabBar)
		.sensoryFeedback(.selection, trigger: mode)
		.sheet(isPresented: $showPicker) {
			if let client = app.client { PracticeMaterialPicker(client: client, picks: $picks) }
		}
		.onAppear { focused = true }
	}

	/// Practice material: the picked nodes as removable chips, then "Pick nodes".
	private var material: some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack {
				CardLabel(text: picks.isEmpty ? "Material" : "Material · \(picks.count) \(picks.count == 1 ? "node" : "nodes")")
				Spacer()
				if !picks.isEmpty {
					QuietButton(title: "Clear") { picks = [] }
				}
			}
			FlowLayout(spacing: 8) {
				ForEach(picks, id: \.id) { pick in
					NodeChip(name: pick.name) { picks.removeAll { $0.id == pick.id } }
				}
				Button { showPicker = true } label: {
					Label("Pick nodes", systemImage: "plus")
						.font(LHFont.prose(.subheadline).weight(.medium))
						.foregroundStyle(LHColor.ink)
						.padding(.horizontal, 14)
						.frame(minHeight: 44)
						.overlay(Capsule().strokeBorder(LHColor.edge, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
						.contentShape(Capsule())
				}
				.buttonStyle(.plain)
			}
		}
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
				Group {
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
									.font(LHFont.prose(.caption))
									.textCase(nil)
							}
						}
					}
				}
				.lhRows()
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
			.lhScreen()
			.lhSheet()
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

/// A session type: a tappable card, outlined in ink when chosen.
private struct ModeCard: View {
	let title: String
	let systemImage: String
	let detail: String
	let selected: Bool
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			VStack(alignment: .leading, spacing: 8) {
				HStack {
					Image(systemName: systemImage)
					Spacer()
					Image(systemName: selected ? "largecircle.fill.circle" : "circle")
						.foregroundStyle(selected ? LHColor.ink : LHColor.muted)
				}
				.font(.system(size: 17))
				Text(title).font(LHFont.title(19, relativeTo: .title3)).foregroundStyle(LHColor.ink)
				Text(detail).font(LHFont.prose(.subheadline)).foregroundStyle(LHColor.muted)
					.fixedSize(horizontal: false, vertical: true)
			}
			.padding(14)
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
			.background(RoundedRectangle(cornerRadius: 14).fill(LHColor.raised))
			.overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? LHColor.ink : LHColor.hairline, lineWidth: selected ? 1.5 : 1))
			.contentShape(RoundedRectangle(cornerRadius: 14))
		}
		.buttonStyle(.plain)
		.foregroundStyle(LHColor.ink)
		.accessibilityAddTraits(selected ? .isSelected : [])
	}
}

/// A picked node: its name and a remove button, 44 pt tall.
private struct NodeChip: View {
	let name: String
	let remove: () -> Void

	var body: some View {
		HStack(spacing: 2) {
			Text(name).font(LHFont.prose(.subheadline)).foregroundStyle(LHColor.ink).lineLimit(1)
				.padding(.leading, 14)
			Button(action: remove) {
				Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(LHColor.muted)
					.frame(width: 36, height: 44)
					.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.accessibilityLabel("Remove \(name)")
		}
		.frame(minHeight: 44)
		.background(Capsule().fill(LHColor.raised))
		.overlay(Capsule().strokeBorder(LHColor.hairline))
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
					Text(proposition.name).font(LHFont.prose(.subheadline).weight(.medium)).foregroundStyle(.primary)
					Text(proposition.statement).font(LHFont.prose(.caption)).foregroundStyle(.secondary).lineLimit(3)
				}
			}
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.accessibilityAddTraits(isSelected ? .isSelected : [])
	}
}
