import LHAPI
import LHRender
import SwiftUI

enum SidebarSelection: Hashable {
	case new
	case chat(String)
}

/// The session list (iPad: sidebar; iPhone: stack): new, open, rename,
/// delete. Refreshes on server notifications; falls back to the offline copy.
struct SessionsView: View {
	@Environment(AppModel.self) private var model
	@State private var chats: [ChatListItem] = []
	@State private var selection: SidebarSelection?
	@State private var filter: SessionFilter = .all
	@State private var query = ""
	@State private var offline = false
	@State private var error: String?
	@State private var renaming: ChatListItem?
	@State private var showRename = false
	@State private var renameText = ""
	@State private var deleting: ChatListItem?
	@State private var listener: UUID?
	/// A refresh announced by server events, waiting out the debounce.
	@State private var pendingRefresh: Task<Void, Never>?
	/// Bumped by every load: only the latest one's answer is shown.
	@State private var loadGeneration = 0

	var body: some View {
		NavigationSplitView {
			let sections = SessionListSections(chats: chats, filter: filter, query: query)
			List(selection: $selection) {
				Section {
					FilterBar(filter: $filter)
						.listRowBackground(Color.clear)
						.listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
						.listRowSeparator(.hidden)
					if offline {
						Label("Offline — showing saved sessions", systemImage: "wifi.slash")
							.font(LHFont.prose(.footnote))
							.foregroundStyle(LHColor.muted)
							.listRowBackground(Color.clear)
							.listRowSeparator(.hidden)
					}
				}
				if !sections.waiting.isEmpty {
					Section {
						rows(sections.waiting)
					} header: {
						SectionHeader(title: "Waiting for you", count: sections.waiting.count)
					}
				}
				if !sections.recent.isEmpty {
					Section {
						rows(sections.recent)
					} header: {
						SectionHeader(title: "Recent")
					}
				}
			}
			.listStyle(.insetGrouped)
			.scrollContentBackground(.hidden)
			.background(LHColor.bg)
			.searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search sessions")
			.overlay {
				if chats.isEmpty, error == nil, !offline {
					ContentUnavailableView {
						Label("No sessions yet", systemImage: "text.bubble")
					} actions: {
						Button("New session") { selection = .new }
					}
				} else if !chats.isEmpty, sections.isEmpty {
					ContentUnavailableView.search(text: query)
				}
			}
			.navigationTitle("Sessions")
			.toolbar {
				ToolbarItem(placement: .largeTitle) {
					Text("Sessions").font(LHFont.title(34, relativeTo: .largeTitle)).foregroundStyle(LHColor.ink)
						.frame(maxWidth: .infinity, alignment: .leading)
						.accessibilityAddTraits(.isHeader)
				}
				ToolbarItem(placement: .topBarTrailing) {
					Button { selection = .new } label: { Image(systemName: "plus") }
						.accessibilityLabel("New session")
						.disabled(offline)
				}
			}
			.refreshable { await load() }
			.task { await load() }
			.onAppear(perform: subscribe)
			.onAppear(perform: takeRequest)
			.onChange(of: model.sessionRequest) { takeRequest() }
			.onDisappear {
				if let listener { model.events.unsubscribe(listener) }
				listener = nil
				pendingRefresh?.cancel()
				pendingRefresh = nil
			}
			// The target stays set while the alert dismisses; the button reads it.
			.alert("Rename session", isPresented: $showRename, presenting: renaming) { chat in
				TextField("Title", text: $renameText)
				Button("Cancel", role: .cancel) {}
				Button("Rename") { Task { await rename(chat) } }
			}
			.sheet(item: $deleting) { chat in
				DeleteSessionSheet(chat: chat) { mode in await delete(chat, mode: mode) }
					.presentationDetents([.medium])
			}
			.alert("Something went wrong", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
				Button("OK", role: .cancel) {}
			} message: {
				Text(error ?? "")
			}
		} detail: {
			switch selection {
			case .new:
				NewSessionView { id in
					selection = .chat(id)
					Task { await load() }
				}
			case .chat(let id):
				SessionView(chatId: id).id(id)
			case nil:
				ContentUnavailableView("Select a session", systemImage: "sidebar.left")
			}
		}
		// Prose in Source Sans 3 wherever a session view doesn't set its own.
		.font(LHFont.prose())
	}

	@ViewBuilder private func rows(_ list: [ChatListItem]) -> some View {
		ForEach(list) { chat in
			NavigationLink(value: SidebarSelection.chat(chat.id)) {
				SessionRow(chat: chat)
			}
			.listRowBackground(LHColor.raised)
			.swipeActions(edge: .trailing) {
				// Not role: .destructive — that animates the row away before
				// the confirmation, and the list then disagrees with the data.
				Button("Delete", systemImage: "trash") { deleting = chat }
					.tint(LHColor.error)
				Button("Rename", systemImage: "pencil") { startRename(chat) }
					.tint(.blue)
			}
			.contextMenu {
				Button("Rename", systemImage: "pencil") { startRename(chat) }
				Button("Delete", systemImage: "trash", role: .destructive) { deleting = chat }
			}
		}
	}

	private func subscribe() {
		guard listener == nil else { return }
		listener = model.events.subscribe { signal in
			switch signal {
			case .reconnected:
				pendingRefresh?.cancel()
				pendingRefresh = nil
				Task { await load() }
			case .suspended:
				break
			case .event(let event):
				if ["chats-changed", "turn-started", "turn-settled", "record-changed", "compaction-changed"].contains(event.type) {
					scheduleLoad()
				}
			}
		}
	}

	/// Events come in bursts (a turn starting and settling, several sessions
	/// at once): one load 250 ms after the last of them (the web sidebar's
	/// debounce).
	private func scheduleLoad() {
		pendingRefresh?.cancel()
		pendingRefresh = Task {
			try? await Task.sleep(for: .milliseconds(250))
			guard !Task.isCancelled else { return }
			pendingRefresh = nil
			await load()
		}
	}

	/// A session the graph asked to open.
	private func takeRequest() {
		guard let chatId = model.sessionRequest else { return }
		model.sessionRequest = nil
		selection = .chat(chatId)
	}

	private func startRename(_ chat: ChatListItem) {
		renameText = chat.title
		renaming = chat
		showRename = true
	}

	private func rename(_ chat: ChatListItem) async {
		guard let client = model.client else { return }
		let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !title.isEmpty, title != chat.title else { return }
		do {
			try await client.renameChat(chat.id, title: title)
			await load()
		} catch {
			self.error = (error as? APIError)?.message ?? error.localizedDescription
		}
	}

	private func delete(_ chat: ChatListItem, mode: ChatDeleteMode) async {
		guard let client = model.client else { return }
		do {
			try await client.deleteChat(chat.id, mode: mode)
			if selection == .chat(chat.id) { selection = nil }
			chats.removeAll { $0.id == chat.id }
			await model.store?.removeView(chatId: chat.id)
			model.forgetDrafts(for: chat.id)
			await load()
		} catch {
			self.error = (error as? APIError)?.message ?? error.localizedDescription
		}
	}

	/// Loads can overlap (events, pull to refresh, a rename) and answer out
	/// of order: one superseded meanwhile is dropped, so an older list (a
	/// session still "Working…") never replaces a newer one.
	private func load() async {
		guard let client = model.client, let store = model.store else { return }
		loadGeneration += 1
		let generation = loadGeneration
		do {
			let fresh = try await client.listChats()
			guard generation == loadGeneration else { return }
			chats = fresh
			offline = false
			try? await store.saveChatList(fresh)
		} catch APIError.transport {
			guard generation == loadGeneration else { return }
			offline = true
			let saved = await store.loadChatList()
			guard generation == loadGeneration else { return }
			chats = saved ?? chats
		} catch is CancellationError {
		} catch {
			guard generation == loadGeneration else { return }
			self.error = (error as? APIError)?.message ?? error.localizedDescription
		}
	}
}

private struct SessionRow: View {
	let chat: ChatListItem

	var body: some View {
		HStack(alignment: .firstTextBaseline, spacing: 10) {
			Circle().fill(SessionListSections.waits(chat) ? LHColor.amber : .clear)
				.frame(width: 7, height: 7)
				.alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
				.accessibilityHidden(true)
			VStack(alignment: .leading, spacing: 5) {
				Text(chat.title)
					.font(LHFont.title(17, relativeTo: .body))
					.foregroundStyle(LHColor.ink)
					.lineLimit(2)
				HStack(spacing: 6) {
					if chat.busy { ProgressView().controlSize(.mini) }
					Text(status)
						.lhLabel(10)
						.foregroundStyle(SessionListSections.waits(chat) && !chat.busy ? LHColor.amber : LHColor.muted)
						.lineLimit(1)
				}
			}
		}
		.padding(.vertical, 4)
		.accessibilityElement(children: .combine)
	}

	private var status: String {
		var parts = [chat.kind == .practice ? "Practice" : "Teaching"]
		if chat.busy { parts.append("Working…") }
		else if chat.compacting { parts.append("Compacting…") }
		else if chat.pendingQuestion { parts.append("Question waiting") }
		else if chat.pendingProblem { parts.append("Problem open") }
		if let age = RelativeAge.label(updatedAt: chat.updatedAt) { parts.append(age) }
		return parts.joined(separator: " · ")
	}
}

/// A list section's mono header, with the count when given.
private struct SectionHeader: View {
	let title: String
	var count: Int?

	var body: some View {
		HStack(spacing: 6) {
			Text(title)
			if let count { Text("\(count)").foregroundStyle(LHColor.amber) }
		}
		.lhLabel()
		.foregroundStyle(LHColor.muted)
	}
}

/// TEACHING / PRACTICE / ALL.
private struct FilterBar: View {
	@Binding var filter: SessionFilter

	var body: some View {
		HStack(spacing: 2) {
			ForEach(SessionFilter.allCases, id: \.self) { option in
				Button { filter = option } label: {
					Text(option.title)
						.lhLabel()
						.foregroundStyle(filter == option ? LHColor.ink : LHColor.muted)
						.frame(maxWidth: .infinity, minHeight: 36)
						.background(RoundedRectangle(cornerRadius: 9).fill(filter == option ? LHColor.edge.opacity(0.6) : .clear))
						.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				.accessibilityAddTraits(filter == option ? .isSelected : [])
			}
		}
		.padding(3)
		.background(RoundedRectangle(cornerRadius: 12).fill(LHColor.raised))
		.overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(LHColor.hairline))
		.sensoryFeedback(.selection, trigger: filter)
	}
}

/// The web's delete dialog: one unchecked-by-default option to also remove
/// the session's knowledge-graph traces.
private struct DeleteSessionSheet: View {
	let chat: ChatListItem
	let onDelete: (ChatDeleteMode) async -> Void
	@State private var removeTraces = false
	@State private var busy = false
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		NavigationStack {
			Form {
				Section {
					Text(chat.title).font(.headline)
					Text("The session and its background work are deleted. Knowledge it contributed to your graph stays unless you remove it too.")
						.font(.callout).foregroundStyle(.secondary)
				}
				Section {
					Toggle("Also remove its graph traces", isOn: $removeTraces)
				}
			}
			.navigationTitle("Delete session")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
				ToolbarItem(placement: .destructiveAction) {
					Button("Delete", role: .destructive) {
						busy = true
						Task {
							await onDelete(removeTraces ? .deleteNodes : .preserveGraph)
							dismiss()
						}
					}
					.disabled(busy)
				}
			}
		}
	}
}
