import LHAPI
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
	@State private var offline = false
	@State private var error: String?
	@State private var renaming: ChatListItem?
	@State private var showRename = false
	@State private var renameText = ""
	@State private var deleting: ChatListItem?
	@State private var listener: UUID?

	var body: some View {
		NavigationSplitView {
			List(selection: $selection) {
				if offline {
					Label("Offline — showing saved sessions", systemImage: "wifi.slash")
						.font(.footnote)
						.foregroundStyle(.secondary)
				}
				ForEach(chats) { chat in
					NavigationLink(value: SidebarSelection.chat(chat.id)) {
						SessionRow(chat: chat)
					}
					.swipeActions(edge: .trailing) {
						// Not role: .destructive — that animates the row away before
						// the confirmation, and the list then disagrees with the data.
						Button("Delete", systemImage: "trash") { deleting = chat }
							.tint(.red)
						Button("Rename", systemImage: "pencil") { startRename(chat) }
							.tint(.blue)
					}
					.contextMenu {
						Button("Rename", systemImage: "pencil") { startRename(chat) }
						Button("Delete", systemImage: "trash", role: .destructive) { deleting = chat }
					}
				}
			}
			.overlay {
				if chats.isEmpty, error == nil, !offline {
					ContentUnavailableView {
						Label("No sessions yet", systemImage: "text.bubble")
					} actions: {
						Button("New session") { selection = .new }
					}
				}
			}
			.navigationTitle("Sessions")
			.toolbar {
				ToolbarItem(placement: .topBarTrailing) {
					Button { selection = .new } label: { Image(systemName: "square.and.pencil") }
						.accessibilityLabel("New session")
						.disabled(offline)
				}
			}
			.refreshable { await load() }
			.task { await load() }
			.onAppear(perform: subscribe)
			.onAppear(perform: takeRequest)
			.onChange(of: model.sessionRequest) { takeRequest() }
			.onDisappear { if let listener { model.events.unsubscribe(listener) }; listener = nil }
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
	}

	private func subscribe() {
		guard listener == nil else { return }
		listener = model.events.subscribe { signal in
			switch signal {
			case .reconnected:
				Task { await load() }
			case .event(let event):
				if ["chats-changed", "turn-started", "turn-settled", "record-changed", "compaction-changed"].contains(event.type) {
					Task { await load() }
				}
			}
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
			await load()
		} catch {
			self.error = (error as? APIError)?.message ?? error.localizedDescription
		}
	}

	private func load() async {
		guard let client = model.client, let store = model.store else { return }
		do {
			let fresh = try await client.listChats()
			chats = fresh
			offline = false
			try? await store.saveChatList(fresh)
		} catch APIError.unauthorized {
			error = "The server rejected the saved access token. Sign out and connect again."
		} catch APIError.transport {
			offline = true
			chats = await store.loadChatList() ?? chats
		} catch is CancellationError {
		} catch {
			self.error = (error as? APIError)?.message ?? error.localizedDescription
		}
	}
}

private struct SessionRow: View {
	let chat: ChatListItem

	var body: some View {
		VStack(alignment: .leading, spacing: 2) {
			Text(chat.title).lineLimit(2)
			HStack(spacing: 6) {
				if chat.busy { ProgressView().controlSize(.mini) }
				Text(subtitle).font(.caption).foregroundStyle(.secondary)
			}
		}
	}

	private var subtitle: String {
		var parts = [chat.kind == .practice ? "Practice" : "Teaching"]
		if chat.busy { parts.append("Working…") }
		else if chat.compacting { parts.append("Compacting…") }
		else if chat.pendingQuestion { parts.append("Question waiting") }
		else if chat.pendingProblem { parts.append("Problem open") }
		return parts.joined(separator: " · ")
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
