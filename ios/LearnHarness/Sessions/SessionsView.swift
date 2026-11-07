import LHAPI
import SwiftUI

/// The session list (iPad: sidebar; iPhone: stack). Falls back to the
/// offline copy when the server can't be reached.
struct SessionsView: View {
	@Environment(AppModel.self) private var model
	@State private var chats: [ChatListItem] = []
	@State private var selection: String?
	@State private var offline = false
	@State private var error: String?

	var body: some View {
		NavigationSplitView {
			List(selection: $selection) {
				if offline {
					Label("Offline — showing saved sessions", systemImage: "wifi.slash")
						.font(.footnote)
						.foregroundStyle(.secondary)
				}
				ForEach(chats) { chat in
					NavigationLink(value: chat.id) {
						VStack(alignment: .leading, spacing: 2) {
							Text(chat.title).lineLimit(2)
							Text(subtitle(chat)).font(.caption).foregroundStyle(.secondary)
						}
					}
				}
			}
			.overlay {
				if chats.isEmpty, error == nil {
					ContentUnavailableView("No sessions yet", systemImage: "text.bubble")
				}
			}
			.navigationTitle("Sessions")
			.toolbar {
				ToolbarItem(placement: .topBarTrailing) {
					Menu {
						Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
							Task { await model.signOut() }
						}
					} label: {
						Image(systemName: "ellipsis.circle")
					}
				}
			}
			.refreshable { await load() }
			.task { await load() }
			.alert("Couldn't load sessions", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
				Button("OK", role: .cancel) {}
			} message: {
				Text(error ?? "")
			}
		} detail: {
			if let selection {
				TranscriptView(chatId: selection)
					.id(selection)
			} else {
				ContentUnavailableView("Select a session", systemImage: "sidebar.left")
			}
		}
	}

	private func subtitle(_ chat: ChatListItem) -> String {
		var parts = [chat.kind == .practice ? "Practice" : "Teaching"]
		if chat.busy { parts.append("Working…") } else if chat.pendingQuestion { parts.append("Question waiting") }
		else if chat.pendingProblem { parts.append("Problem open") }
		return parts.joined(separator: " · ")
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
