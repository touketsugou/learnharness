import LHAPI
import SwiftUI

/// The chains & sources manager (web chain table): folders → sources →
/// reasoning chains → statements. Organize with rename / move / new folder;
/// select sources and folders to delete them.
struct SourcesView: View {
	/// The Graph tab's home when rendering is off: its own actions in place
	/// of Done, and the graph status pills above the list.
	struct Home {
		var actions: AnyView
		var status: AnyView
	}

	let model: GraphModel
	var home: Home?
	/// Show a node (on the canvas, or its details at home).
	let onShowNode: (String) -> Void

	@Environment(\.dismiss) private var dismiss
	@State private var query = ""
	@State private var sort: SourceTree.Sort = .name
	@State private var ascending = true
	@State private var selecting = false
	@State private var selectedSources: Set<String> = []
	@State private var selectedFolders: Set<String> = []
	@State private var naming: NamingTask?
	@State private var nameText = ""
	@State private var moving: MoveTask?
	@State private var deleting = false
	@State private var error: String?

	private var tree: SourceTree? {
		model.snapshot.map { SourceTree.build(snapshot: $0, directory: model.directory) }
	}

	var body: some View {
		NavigationStack {
			Group {
				if let tree, let snapshot = model.snapshot {
					List {
						if query.trimmingCharacters(in: .whitespaces).isEmpty {
							folderContents(nil, tree: tree, snapshot: snapshot)
						} else {
							let hits = SourceTree.sorted(tree.searched(query, snapshot: snapshot), by: sort, ascending: ascending)
							if hits.isEmpty { Text("No matching chains.").foregroundStyle(.secondary) }
							ForEach(hits) { group in sourceRow(group, snapshot: snapshot, expanded: true) }
						}
					}
					.listStyle(.sidebar)
					.safeAreaInset(edge: .top, spacing: 0) { home?.status }
					.refreshable { if home != nil { await model.reload() } }
				} else if let error = model.error, home != nil {
					ContentUnavailableView("Couldn’t load the graph", systemImage: "exclamationmark.triangle", description: Text(error))
				} else {
					ProgressView()
				}
			}
			.searchable(text: $query, prompt: "Search chains")
			.navigationTitle(home == nil ? "Chains & sources" : "Graph")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar { toolbar }
			.alert(naming?.title ?? "", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } }), presenting: naming) { task in
				TextField("Name", text: $nameText)
				Button("Cancel", role: .cancel) {}
				Button(task.confirm) { Task { await finishNaming(task) } }
			}
			.sheet(item: $moving) { task in
				if let tree { MoveSheet(task: task, tree: tree) { parent in Task { await move(task, to: parent) } } }
			}
			.sheet(isPresented: $deleting) {
				if let tree {
					DeleteSourcesSheet(
						sources: tree.groups.filter { selectedSources.contains($0.id) },
						folders: tree.folders.filter { selectedFolders.contains($0.id) }
					) { deleteSessions in
						try await model.deleteSources(sourceIds: Array(selectedSources), folderIds: Array(selectedFolders), deleteSessions: deleteSessions)
						selectedSources = []
						selectedFolders = []
						selecting = false
					}
					.presentationDetents([.medium, .large])
				}
			}
			.alert("Couldn’t update sources", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
				Button("OK", role: .cancel) {}
			} message: {
				Text(error ?? "")
			}
		}
	}

	// MARK: Tree

	private func folderContents(_ parent: String?, tree: SourceTree, snapshot: GraphSnapshot) -> AnyView {
		AnyView(Group {
			ForEach(tree.folders(in: parent, sort: sort == .props ? .name : sort, ascending: ascending)) { folder in
				DisclosureGroup {
					folderContents(folder.id, tree: tree, snapshot: snapshot)
				} label: {
					selectable(folder: folder.id) {
						Label(folder.name, systemImage: "folder")
					}
					.contextMenu { folderMenu(folder, tree: tree) }
				}
			}
			ForEach(tree.groups(in: parent, sort: sort, ascending: ascending)) { group in
				sourceRow(group, snapshot: snapshot, expanded: false)
			}
		})
	}

	@ViewBuilder private func sourceRow(_ group: SourceTree.Group, snapshot: GraphSnapshot, expanded: Bool) -> some View {
		let label = selectable(source: group.id) {
			HStack {
				Label {
					// Empty and unlabeled sources read muted, as on the web.
					Text(group.label).foregroundStyle(group.isEmpty || group.isUnlabeled ? .secondary : .primary)
				} icon: {
					Image(systemName: icon(group))
				}
				Spacer()
				if group.nodeCount > 0 {
					Text("\(group.nodeCount)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
				}
			}
		}
		.contextMenu { sourceMenu(group) }
		if group.isEmpty {
			label
		} else {
			ExpandableRow(initiallyExpanded: expanded) {
				ForEach(group.chains) { chain in
					DisclosureGroup {
						ForEach(chain.premises + [chain.conclusion], id: \.self) { id in
							statement(id, snapshot: snapshot)
						}
					} label: {
						ChainLine(chain: chain, snapshot: snapshot, current: nil) { id in onShowNode(id) }
					}
				}
				ForEach(group.singletons) { proposition in
					DisclosureGroup {
						Text(proposition.statement).font(.callout).foregroundStyle(.secondary)
					} label: {
						Button(proposition.name) { onShowNode(proposition.id) }
							.buttonStyle(.plain)
							.font(.callout)
							.padding(.horizontal, 8)
							.padding(.vertical, 3)
							.overlay(Capsule().strokeBorder(Color.secondary.opacity(0.4)))
					}
				}
			} label: {
				label
			}
		}
	}

	private func statement(_ id: String, snapshot: GraphSnapshot) -> some View {
		let node = snapshot.propositions.first { $0.id == id }
		return VStack(alignment: .leading, spacing: 2) {
			Text(node?.name ?? "Deleted node").font(.callout.weight(.medium))
			Text(node?.statement ?? "").font(.callout).foregroundStyle(.secondary)
		}
	}

	private func icon(_ group: SourceTree.Group) -> String {
		switch group.entry?.kind {
		case "notes": "doc.text"
		case "chat": "text.bubble"
		default: "questionmark.square.dashed"
		}
	}

	/// In select mode a row leads with a checkbox.
	private func selectable(source: String? = nil, folder: String? = nil, @ViewBuilder content: () -> some View) -> some View {
		HStack(spacing: 10) {
			if selecting {
				let on = source.map(selectedSources.contains) ?? folder.map(selectedFolders.contains) ?? false
				Button {
					if let source { selectedSources.formSymmetricDifference([source]) }
					if let folder { selectedFolders.formSymmetricDifference([folder]) }
				} label: {
					Image(systemName: on ? "checkmark.circle.fill" : "circle")
						.foregroundStyle(on ? Color.accentColor : .secondary)
				}
				.buttonStyle(.plain)
				.accessibilityLabel(on ? "Deselect" : "Select")
			}
			content()
		}
	}

	// MARK: Menus and actions

	@ToolbarContentBuilder private var toolbar: some ToolbarContent {
		ToolbarItem(placement: .cancellationAction) {
			if let home { home.actions } else { Button("Done") { dismiss() } }
		}
		ToolbarItemGroup(placement: .primaryAction) {
			Menu {
				Picker("Sort by", selection: $sort) {
					Text("Name").tag(SourceTree.Sort.name)
					Text("Propositions").tag(SourceTree.Sort.props)
					Text("Created").tag(SourceTree.Sort.created)
				}
				Toggle("Ascending", isOn: $ascending)
			} label: {
				Image(systemName: "arrow.up.arrow.down")
			}
			.accessibilityLabel("Sort")
			Button(selecting ? "Cancel" : "Select") {
				selecting.toggle()
				selectedSources = []
				selectedFolders = []
			}
			.disabled(model.offline)
		}
		ToolbarItemGroup(placement: .bottomBar) {
			if selecting {
				let count = selectedSources.count + selectedFolders.count
				Text(count == 0 ? "Select sources or folders" : "\(count) selected").font(.footnote).foregroundStyle(.secondary)
				Spacer()
				Button("Delete", role: .destructive) { deleting = true }
					.disabled(count == 0)
			} else {
				Button("New Folder", systemImage: "folder.badge.plus") { startNaming(.newFolder(parent: nil)) }
					.disabled(model.offline)
				Spacer()
			}
		}
	}

	@ViewBuilder private func folderMenu(_ folder: SourceFolder, tree: SourceTree) -> some View {
		Button("Rename", systemImage: "pencil") { startNaming(.renameFolder(folder)) }
		Button("New Folder Inside", systemImage: "folder.badge.plus") { startNaming(.newFolder(parent: folder.id)) }
		Button("Move to…", systemImage: "folder") { moving = MoveTask(kind: .folder(folder)) }
		if tree.isEmptyFolder(folder.id) {
			Button("Delete Empty Folder", systemImage: "trash", role: .destructive) {
				Task { await run(.deleteFolder(id: folder.id)) }
			}
		}
	}

	@ViewBuilder private func sourceMenu(_ group: SourceTree.Group) -> some View {
		if group.entry != nil, group.entry?.kind != "missing" {
			Button("Rename", systemImage: "pencil") { startNaming(.renameSource(group)) }
			Button("Move to…", systemImage: "folder") { moving = MoveTask(kind: .source(group)) }
		}
	}

	private func startNaming(_ task: NamingTask) {
		nameText = task.initial
		naming = task
	}

	private func finishNaming(_ task: NamingTask) async {
		let name = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !name.isEmpty, name != task.initial else { return }
		switch task {
		case .newFolder(let parent): await run(.createFolder(name: name, parentId: parent))
		case .renameFolder(let folder): await run(.renameFolder(id: folder.id, name: name))
		case .renameSource(let group): await run(.renameSource(id: group.id, name: name))
		}
	}

	private func move(_ task: MoveTask, to parent: String?) async {
		switch task.kind {
		case .source(let group): await run(.moveSource(id: group.id, parentId: parent))
		case .folder(let folder): await run(.moveFolder(id: folder.id, parentId: parent))
		}
	}

	private func run(_ action: SourceAction) async {
		do {
			try await model.change(action)
		} catch {
			self.error = (error as? APIError)?.message ?? error.localizedDescription
		}
	}
}

/// A name prompt: new folder, or a rename.
enum NamingTask: Identifiable {
	case newFolder(parent: String?)
	case renameFolder(SourceFolder)
	case renameSource(SourceTree.Group)

	var id: String {
		switch self {
		case .newFolder(let parent): "new-\(parent ?? "root")"
		case .renameFolder(let folder): "folder-\(folder.id)"
		case .renameSource(let group): "source-\(group.id)"
		}
	}

	var title: String {
		switch self {
		case .newFolder: "New folder"
		case .renameFolder: "Rename folder"
		case .renameSource: "Rename source"
		}
	}

	var confirm: String {
		if case .newFolder = self { return "Create" }
		return "Rename"
	}

	var initial: String {
		switch self {
		case .newFolder: ""
		case .renameFolder(let folder): folder.name
		case .renameSource(let group): group.label
		}
	}
}

struct MoveTask: Identifiable {
	enum Kind {
		case source(SourceTree.Group)
		case folder(SourceFolder)
	}

	let id = UUID()
	let kind: Kind
}

/// Pick the destination folder (or the top level) for a move.
private struct MoveSheet: View {
	let task: MoveTask
	let tree: SourceTree
	let onMove: (String?) -> Void
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		NavigationStack {
			List {
				destination(nil, name: "Top level", depth: 0)
				folders(in: nil, depth: 0)
			}
			.navigationTitle("Move to")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
			}
		}
		.presentationDetents([.medium, .large])
	}

	private func folders(in parent: String?, depth: Int) -> AnyView {
		AnyView(ForEach(tree.folders(in: parent)) { folder in
			if !blocked(folder.id) {
				destination(folder.id, name: folder.name, depth: depth + 1)
				folders(in: folder.id, depth: depth + 1)
			}
		})
	}

	private func destination(_ id: String?, name: String, depth: Int) -> some View {
		Button {
			onMove(id)
			dismiss()
		} label: {
			HStack {
				Label(name, systemImage: id == nil ? "tray" : "folder")
				Spacer()
				if id == current { Image(systemName: "checkmark").foregroundStyle(.secondary) }
			}
			.padding(.leading, CGFloat(depth) * 16)
		}
		.disabled(id == current)
	}

	private var current: String? {
		switch task.kind {
		case .source(let group): group.folderId
		case .folder(let folder): folder.parentId
		}
	}

	/// A folder can't move into itself or its descendants.
	private func blocked(_ id: String) -> Bool {
		if case .folder(let folder) = task.kind { return tree.isWithin(id, folder: folder.id) }
		return false
	}
}

/// The web's source deletion confirmation, with its one option.
private struct DeleteSourcesSheet: View {
	let sources: [SourceTree.Group]
	let folders: [SourceFolder]
	let onDelete: (Bool) async throws -> Void

	@Environment(\.dismiss) private var dismiss
	@State private var deleteSessions = false
	@State private var busy = false
	@State private var failure: String?

	private var chats: [SourceTree.Group] { sources.filter { $0.entry?.kind == "chat" } }

	var body: some View {
		NavigationStack {
			Form {
				Section {
					Text("Delete selected sources and folders?").font(.headline).foregroundStyle(.red)
					let names = sources.map(\.label) + folders.map(\.name)
					Text(names.prefix(8).joined(separator: ", ") + (names.count > 8 ? ", and \(names.count - 8) more" : ""))
						.font(.callout.monospaced())
					if !sources.isEmpty {
						Text("Removes these sources’ contributions to propositions and reasoning chains. Knowledge supported by other sources survives; knowledge supported only by these sources is removed.")
							.font(.callout).foregroundStyle(.secondary)
					}
					Text("Imported source records are removed, but original files on disk are never changed. Selected folders are removed only when empty; folders needed by kept sessions remain.")
						.font(.footnote).foregroundStyle(.secondary)
				}
				if !chats.isEmpty {
					Section {
						Toggle("Also delete the \(chats.count) selected \(chats.count == 1 ? "session" : "sessions")", isOn: $deleteSessions)
							.disabled(busy)
					} footer: {
						Text("Unchecked, conversations stay in their current folders and can be extracted again. Either way, their graph contributions and extraction coverage are cleared. Checking this also permanently deletes their messages and background jobs.")
					}
				}
				if let failure {
					Section { Text(failure).foregroundStyle(.red) }
				}
			}
			.navigationTitle("Delete")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
				ToolbarItem(placement: .destructiveAction) {
					Button(busy ? "Deleting…" : failure == nil ? "Delete" : "Try again", role: .destructive) {
						busy = true
						failure = nil
						Task {
							do {
								try await onDelete(deleteSessions)
								dismiss()
							} catch {
								failure = (error as? APIError)?.message ?? error.localizedDescription
							}
							busy = false
						}
					}
					.disabled(busy)
				}
			}
		}
	}
}

/// A disclosure row with its own expansion state (search results start open).
private struct ExpandableRow<Content: View, Label: View>: View {
	@State private var expanded: Bool
	let content: Content
	let label: Label

	init(initiallyExpanded: Bool, @ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
		_expanded = State(initialValue: initiallyExpanded)
		self.content = content()
		self.label = label()
	}

	var body: some View {
		DisclosureGroup(isExpanded: $expanded) { content } label: { label }
	}
}
