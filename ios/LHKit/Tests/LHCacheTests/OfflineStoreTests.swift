import Foundation
import Testing
@testable import LHAPI
@testable import LHCache

@Suite("Offline store")
struct OfflineStoreTests {
	let root = FileManager.default.temporaryDirectory.appending(path: "lh-cache-\(UUID().uuidString)")

	var store: OfflineStore { OfflineStore(root: root.appending(path: "support"), imageRoot: root.appending(path: "images")) }

	func fixtureView() throws -> NativeSessionView {
		let url = URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
			.deletingLastPathComponent().deletingLastPathComponent()
			.appending(path: "tests/fixtures/native/pending-quiz.view.json")
		return try JSONDecoder().decode(NativeSessionView.self, from: Data(contentsOf: url))
	}

	@Test func roundTripsViewsListsGraphAndImages() async throws {
		let store = store
		let view = try fixtureView()
		try await store.saveView(view)
		#expect(await store.loadView(chatId: view.chatId) == view)
		#expect(await store.cachedChatIds() == [view.chatId])

		let item = ChatListItem(id: "chat/odd id", title: "T", createdAt: "a", updatedAt: "b", kind: .practice, messageCount: 3,
								phase: nil, pendingQuestion: false, pendingProblem: true, settings: nil, busy: false, compacting: false)
		try await store.saveChatList([item])
		#expect(await store.loadChatList() == [item])

		try await store.saveGraph(Data("{\"nodes\":[]}".utf8))
		#expect(await store.loadGraph() == Data("{\"nodes\":[]}".utf8))

		try await store.saveImage(chatId: "chat/odd id", snapshotId: "sha:1", data: Data([1, 2, 3]))
		#expect(await store.loadImage(chatId: "chat/odd id", snapshotId: "sha:1") == Data([1, 2, 3]))
	}

	@Test func removesAndClears() async throws {
		let store = store
		let view = try fixtureView()
		try await store.saveView(view)
		await store.removeView(chatId: view.chatId)
		#expect(await store.loadView(chatId: view.chatId) == nil)
		try await store.saveView(view)
		await store.clearAll()
		#expect(await store.loadView(chatId: view.chatId) == nil)
		#expect(await store.loadChatList() == nil)
	}

	@Test func idsNeverEscapeTheStore() {
		#expect(OfflineStore.safeName("../../etc/passwd") == "%2E%2E%2F%2E%2E%2Fetc%2Fpasswd")
		#expect(OfflineStore.unsafeName(OfflineStore.safeName("chat_a/b")) == "chat_a/b")
	}

	@Test func serversAreIsolated() async throws {
		let a = OfflineStore.forServer(URL(string: "https://a-\(UUID().uuidString).example")!)
		let b = OfflineStore.forServer(URL(string: "https://b-\(UUID().uuidString).example")!)
		defer { Task { await a.clearAll(); await b.clearAll() } }
		try await a.saveChatList([])
		#expect(await a.loadChatList() == [])
		#expect(await b.loadChatList() == nil, "another server never sees this server's copies")
	}
}
