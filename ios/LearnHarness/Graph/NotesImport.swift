import Foundation
import LHAPI
import Observation
import UniformTypeIdentifiers

/// Notes import (web createNotesImportQueue): one request per file, at most
/// three in flight; failures and notices are kept per file. Never retried —
/// an ambiguous response may already have merged.
@MainActor
@Observable
final class NotesImportQueue {
	struct Message: Identifiable, Hashable {
		let id = UUID()
		let text: String
		let isError: Bool
	}

	nonisolated static let maxBytes = 25 * 1024 * 1024
	nonisolated static let fileTypes: [UTType] = [.plainText, .pdf] + ["md", "markdown"].compactMap { UTType(filenameExtension: $0) }

	private(set) var messages: [Message] = []
	private(set) var active = 0
	private(set) var completed = 0
	@ObservationIgnored private var pending: [NotesFile] = []
	@ObservationIgnored private let client: APIClient

	init(client: APIClient) {
		self.client = client
	}

	var importing: Bool { active > 0 || !pending.isEmpty }
	var remaining: Int { active + pending.count }

	func clearMessages() { messages = [] }

	func append(_ selection: NotesSelection) {
		for problem in selection.problems { messages.append(Message(text: problem, isError: true)) }
		pending += selection.files
		pump()
	}

	private func pump() {
		while active < 3, !pending.isEmpty {
			let file = pending.removeFirst()
			active += 1
			Task { await run(file) }
		}
	}

	private func run(_ file: NotesFile) async {
		do {
			let result = try await client.importNotes(file)
			if !result.ok {
				let code = result.code.map { "\n\($0)" } ?? ""
				messages.append(Message(text: "\(result.filePath): \(result.error ?? result.outcome)\(code)", isError: true))
			} else if let notice = result.notice {
				messages.append(Message(text: "\(result.filePath): \(notice)", isError: false))
			}
		} catch {
			let reason = (error as? APIError)?.message ?? error.localizedDescription
			messages.append(Message(text: "\(file.path): \(reason) Check the graph before retrying.", isError: true))
		}
		active -= 1
		completed += 1
		pump()
	}
}

/// Files read from a Files selection, with folder-relative paths.
struct NotesSelection {
	var files: [NotesFile] = []
	var problems: [String] = []

	/// Individually picked files: each path is its file name.
	static func files(_ urls: [URL]) -> NotesSelection {
		var selection = NotesSelection()
		for url in urls { selection.read(url, path: url.lastPathComponent) }
		return selection
	}

	/// A picked folder: every non-hidden file below it, paths starting with
	/// the folder's own name (web webkitRelativePath).
	static func folder(_ root: URL) -> NotesSelection {
		var selection = NotesSelection()
		let scoped = root.startAccessingSecurityScopedResource()
		defer { if scoped { root.stopAccessingSecurityScopedResource() } }
		let keys: [URLResourceKey] = [.isRegularFileKey]
		guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
			selection.problems.append("\(root.lastPathComponent): the folder couldn’t be read.")
			return selection
		}
		let base = root.standardizedFileURL.pathComponents
		for case let url as URL in walker {
			guard (try? url.resourceValues(forKeys: Set(keys)).isRegularFile) == true else { continue }
			let relative = url.standardizedFileURL.pathComponents.dropFirst(base.count)
			selection.read(url, path: ([root.lastPathComponent] + relative).joined(separator: "/"), scoped: false)
		}
		if selection.files.isEmpty && selection.problems.isEmpty {
			selection.problems.append("\(root.lastPathComponent): the folder has no files.")
		}
		return selection
	}

	private mutating func read(_ url: URL, path: String, scoped: Bool = true) {
		let access = scoped && url.startAccessingSecurityScopedResource()
		defer { if access { url.stopAccessingSecurityScopedResource() } }
		guard let data = try? Data(contentsOf: url) else {
			problems.append("\(path): the file couldn’t be read.")
			return
		}
		guard data.count <= NotesImportQueue.maxBytes else {
			problems.append("\(path): Too big. Max 25 MB.")
			return
		}
		files.append(NotesFile(path: path, data: data))
	}
}
