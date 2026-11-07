import LHAPI
import SwiftUI
import UniformTypeIdentifiers

/// The Graph tab: the read-only canvas with search, node details, the
/// chains & sources manager, notes import and the running extractions.
struct GraphScreen: View {
	@Environment(AppModel.self) private var app
	@State private var model: GraphModel?

	var body: some View {
		NavigationStack {
			if let model {
				GraphContent(model: model)
			} else {
				ProgressView()
			}
		}
		.task {
			guard model == nil, let client = app.client, let store = app.store else { return }
			let graph = GraphModel(client: client, store: store, events: app.events)
			model = graph
			graph.start()
		}
	}
}

private struct GraphContent: View {
	let model: GraphModel
	@Environment(AppModel.self) private var app
	@State private var query = ""
	@State private var scene: GraphScene?
	@State private var camera: GraphGeometry.Camera?
	@State private var request = CameraRequest()
	@State private var selected: String?
	@State private var showSources = false
	@State private var pickFiles = false
	@State private var pickFolder = false

	var body: some View {
		ZStack {
			if let snapshot = model.snapshot, !snapshot.nodes.isEmpty, let scene {
				GraphCanvasView(scene: scene, settings: model.settings, selectedID: selected, camera: $camera, request: request) { id in
					selected = id
					// Keep the node in view above the detail sheet.
					if let id { request.focus(id) }
				}
				.ignoresSafeArea(edges: .bottom)
			} else if model.loading {
				ProgressView()
			} else if model.snapshot != nil {
				ContentUnavailableView {
					Label("Knowledge graph", systemImage: "point.3.connected.trianglepath.dotted")
				} description: {
					Text("Start a session to begin learning.\nAttach your material with the paperclip.")
				} actions: {
					importMenu.buttonStyle(.bordered)
				}
			} else if let error = model.error {
				ContentUnavailableView("Couldn’t load the graph", systemImage: "exclamationmark.triangle", description: Text(error))
			}
		}
		.overlay(alignment: .top) { statusStack }
		.navigationTitle("Graph")
		.navigationBarTitleDisplayMode(.inline)
		.searchable(text: $query, prompt: "Search nodes")
		.toolbar {
			ToolbarItem(placement: .topBarLeading) {
				Button { showSources = true } label: { Image(systemName: "list.bullet.indent") }
					.accessibilityLabel("Chains and sources")
			}
			ToolbarItemGroup(placement: .topBarTrailing) {
				Button { request.fit() } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
					.accessibilityLabel("Fit graph")
				importMenu
			}
		}
		.refreshable { await model.reload() }
		.onAppear(perform: rebuild)
		.onChange(of: model.snapshot) { rebuild() }
		.onChange(of: query) { rebuild() }
		.sheet(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
			if let id = selected, let snapshot = model.snapshot, let node = snapshot.propositions.first(where: { $0.id == id }) {
				NodeDetailSheet(node: node, snapshot: snapshot, model: model,
					onSelectNode: { other in
						selected = other
						request.focus(other)
					},
					onOpenSession: { chatId, messageId in
						selected = nil
						app.openSession(chatId, messageId: messageId)
					},
					onDeleted: { selected = nil })
				.id(node.id)
				.presentationDetents([.fraction(0.4), .large])
				.presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.4)))
			}
		}
		.sheet(isPresented: $showSources) {
			SourcesView(model: model) { id in
				showSources = false
				selected = id
				request.focus(id)
			}
		}
		.fileImporter(isPresented: $pickFiles, allowedContentTypes: NotesImportQueue.fileTypes, allowsMultipleSelection: true) { result in
			if case .success(let urls) = result { model.imports.append(NotesSelection.files(urls)) }
		}
		.background {
			// A second importer needs its own host view.
			Color.clear.fileImporter(isPresented: $pickFolder, allowedContentTypes: [.folder]) { result in
				if case .success(let url) = result { model.imports.append(NotesSelection.folder(url)) }
			}
		}
		.onChange(of: model.imports.completed) { Task { await model.reloadGraph() } }
	}

	private func rebuild() {
		guard let snapshot = model.snapshot else { scene = nil; return }
		scene = GraphScene(snapshot: snapshot, query: query)
		if let selected, !(scene?.nodes.contains { $0.id == selected } ?? false) { self.selected = nil }
	}

	private var importMenu: some View {
		Menu {
			Section("For lessons, attach material to a session instead.") {
				Button("Files", systemImage: "doc") { pickFiles = true }
				Button("Folder", systemImage: "folder") { pickFolder = true }
			}
		} label: {
			Label(model.imports.importing ? "Extracting…" : "Extract files…", systemImage: "square.and.arrow.down")
		}
		.disabled(model.offline)
	}

	/// Offline note, running extractions, import progress and results, no-match note.
	@ViewBuilder private var statusStack: some View {
		VStack(spacing: 6) {
			if model.offline {
				StatusPill(text: "Offline — read-only copy", systemImage: "wifi.slash")
			}
			if !model.runs.isEmpty {
				Menu {
					ForEach(model.runs) { run in Text("\(run.title) · \(run.phase)") }
				} label: {
					StatusPill(text: model.runs.count == 1 ? "Extracting 1 source…" : "Extracting \(model.runs.count) sources…", systemImage: "waveform.path.ecg", busy: true)
				}
			}
			if model.imports.importing {
				StatusPill(text: "Extracting files… \(model.imports.remaining) left", systemImage: "square.and.arrow.down", busy: true)
			}
			if !model.imports.messages.isEmpty {
				ImportMessages(queue: model.imports)
			}
			if !query.trimmingCharacters(in: .whitespaces).isEmpty, let scene, scene.nodes.isEmpty {
				StatusPill(text: "No matching nodes.", systemImage: "magnifyingglass")
			}
		}
		.padding(.top, 8)
		.padding(.horizontal, 16)
	}
}

private struct StatusPill: View {
	let text: String
	let systemImage: String
	var busy = false

	var body: some View {
		HStack(spacing: 6) {
			if busy { ProgressView().controlSize(.mini) } else { Image(systemName: systemImage) }
			Text(text)
		}
		.font(.caption)
		.foregroundStyle(.secondary)
		.padding(.horizontal, 10)
		.padding(.vertical, 6)
		.background(.regularMaterial, in: Capsule())
	}
}

private struct ImportMessages: View {
	let queue: NotesImportQueue

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			ForEach(queue.messages) { message in
				Text(message.text)
					.font(.caption)
					.foregroundStyle(message.isError ? .red : .secondary)
					.frame(maxWidth: .infinity, alignment: .leading)
			}
			Button("Dismiss") { queue.clearMessages() }
				.font(.caption)
				.frame(maxWidth: .infinity, alignment: .trailing)
		}
		.padding(10)
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
	}
}
