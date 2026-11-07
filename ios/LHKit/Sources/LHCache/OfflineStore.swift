import CryptoKit
import Foundation
import LHAPI

/// Read-only offline copies for one server (owner 2026-11-07: the session
/// list, every session opened on this device as its last projected view, the
/// latest knowledge-graph snapshot, and learner-image snapshots). JSON files
/// under Application Support; images under Caches (the system may purge them).
/// Nothing here is ever sent back to the server.
public actor OfflineStore {
	private let root: URL
	private let imageRoot: URL
	private let fileManager = FileManager.default

	/// A store rooted at explicit directories (tests).
	public init(root: URL, imageRoot: URL) {
		self.root = root
		self.imageRoot = imageRoot
	}

	/// The store for a server, isolated by a hash of its address.
	public static func forServer(_ baseURL: URL) -> OfflineStore {
		let key = SHA256.hash(data: Data(baseURL.absoluteString.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
		let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
		let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
		return OfflineStore(
			root: support.appending(path: "LearnHarness/servers/\(key)", directoryHint: .isDirectory),
			imageRoot: caches.appending(path: "LearnHarness/servers/\(key)/images", directoryHint: .isDirectory)
		)
	}

	// MARK: Session list

	public func saveChatList(_ chats: [ChatListItem]) throws {
		try write(chats, to: root.appending(path: "chats.json"))
	}

	public func loadChatList() -> [ChatListItem]? {
		read([ChatListItem].self, from: root.appending(path: "chats.json"))
	}

	// MARK: Session views

	public func saveView(_ view: NativeSessionView) throws {
		try write(view, to: viewURL(view.chatId))
	}

	public func loadView(chatId: String) -> NativeSessionView? {
		read(NativeSessionView.self, from: viewURL(chatId))
	}

	public func removeView(chatId: String) {
		try? fileManager.removeItem(at: viewURL(chatId))
		try? fileManager.removeItem(at: imageRoot.appending(path: Self.safeName(chatId), directoryHint: .isDirectory))
	}

	/// Session ids with a stored view.
	public func cachedChatIds() -> Set<String> {
		let directory = root.appending(path: "sessions", directoryHint: .isDirectory)
		let names = (try? fileManager.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
		return Set(names.compactMap { name in
			guard name.hasSuffix(".json") else { return nil }
			return Self.unsafeName(String(name.dropLast(5)))
		})
	}

	// MARK: Knowledge graph (raw JSON; its model lives with the graph screens)

	public func saveGraph(_ data: Data) throws {
		try writeData(data, to: root.appending(path: "graph.json"))
	}

	public func loadGraph() -> Data? {
		try? Data(contentsOf: root.appending(path: "graph.json"))
	}

	// MARK: Learner-image snapshots

	public func saveImage(chatId: String, snapshotId: String, data: Data) throws {
		try writeData(data, to: imageURL(chatId: chatId, snapshotId: snapshotId))
	}

	public func loadImage(chatId: String, snapshotId: String) -> Data? {
		try? Data(contentsOf: imageURL(chatId: chatId, snapshotId: snapshotId))
	}

	// MARK: Housekeeping

	/// Forget everything for this server (sign-out).
	public func clearAll() {
		try? fileManager.removeItem(at: root)
		try? fileManager.removeItem(at: imageRoot)
	}

	// MARK: Files

	private func viewURL(_ chatId: String) -> URL {
		root.appending(path: "sessions/\(Self.safeName(chatId)).json")
	}

	private func imageURL(chatId: String, snapshotId: String) -> URL {
		imageRoot.appending(path: "\(Self.safeName(chatId))/\(Self.safeName(snapshotId))")
	}

	/// Ids become file names: percent-encode anything outside a safe set.
	static func safeName(_ id: String) -> String {
		var allowed = CharacterSet.alphanumerics
		allowed.insert(charactersIn: "-_")
		return id.addingPercentEncoding(withAllowedCharacters: allowed) ?? UUID().uuidString
	}

	static func unsafeName(_ name: String) -> String? { name.removingPercentEncoding }

	private func write<T: Encodable>(_ value: T, to url: URL) throws {
		try writeData(JSONEncoder().encode(value), to: url)
	}

	private func writeData(_ data: Data, to url: URL) throws {
		try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
	}

	private func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
		guard let data = try? Data(contentsOf: url) else { return nil }
		return try? JSONDecoder().decode(T.self, from: data)
	}
}
