import Foundation

// MARK: - The settings record (GET /api/settings, PUT /api/settings/:section)

/// The stored settings record, kept as raw JSON: every write replaces one
/// whole section, so fields this app does not edit must ride along intact
/// (the web's replace-PUT discipline, components/settings/settings-dialog.tsx).
public struct SettingsRecord: Sendable, Hashable {
	public var raw: [String: JSONValue]

	public init(raw: [String: JSONValue] = ["version": .number(1)]) {
		self.raw = raw
	}

	public func section(_ name: String) -> [String: JSONValue] { raw[name]?.objectValue ?? [:] }
}

/// The record plus the server's file-access configuration problem, if any.
public struct SettingsSnapshot: Sendable, Hashable {
	public var record: SettingsRecord
	public var fileAccessError: String?

	init(reply: JSONValue) {
		// {settings: null} is first boot (factory everything), not a failure.
		record = SettingsRecord(raw: reply["settings"]?.objectValue ?? ["version": .number(1)])
		fileAccessError = reply["fileAccessError"]?.stringValue
	}
}

/// Factory values the web shows as placeholders (src/core/settings.ts).
public enum SettingsDefaults {
	public static let compactionThresholdTokens = 150_000
	public static let compactionThresholdFloor = 32_000
	public static let extractionChunkTokens = 4096
	public static let extractionChunkTokensFloor = 500
}

extension APIClient {
	public func settings() async throws -> SettingsSnapshot {
		SettingsSnapshot(reply: try await get("/api/settings", as: JSONValue.self))
	}

	/// Replace one whole section; the reply is the stored record (the server
	/// clamps thinking levels and heals orphaned prompt switches on write).
	@discardableResult
	public func putSettings(_ section: String, _ value: [String: JSONValue]) async throws -> SettingsSnapshot {
		let (data, _) = try await send(try json("PUT", "/api/settings/\(section)", body: JSONValue.object(value)))
		return SettingsSnapshot(reply: try decode(JSONValue.self, from: data))
	}
}

// MARK: - Section composition (pure; mirrors components/settings/agent-section.tsx)

/// The toggleable agent tools (the web's TOGGLE_TOOLS).
public let toggleableTools = ["research", "demo", "visual", "pdf"]

public enum AgentCompose {
	public static func tool(_ agent: [String: JSONValue], _ id: String, on: Bool) -> [String: JSONValue] {
		var next = agent
		var tools = agent["tools"]?.objectValue ?? [:]
		tools[id] = .bool(on)
		next["tools"] = .object(tools)
		return next
	}

	/// Free recall arms `tools.explain`; anything else is multiple choice.
	public static func quizMechanics(_ agent: [String: JSONValue], freeRecall: Bool) -> [String: JSONValue] {
		tool(agent, "explain", on: freeRecall)
	}

	public static func graphTools(_ agent: [String: JSONValue], on: Bool) -> [String: JSONValue] {
		var next = agent
		next["graphTools"] = .object(["enabled": .bool(on)])
		return next
	}

	/// The switch changes only the restriction, never the saved folders.
	public static func fileRestriction(_ agent: [String: JSONValue], restricted: Bool) -> [String: JSONValue] {
		fileAccess(agent, restricted: restricted, folders: folders(agent))
	}

	/// Add one folder (trimmed); duplicates and invalid entries are no-ops.
	public static func addFolder(_ agent: [String: JSONValue], _ folder: String) -> [String: JSONValue] {
		let entry = folder.trimmingCharacters(in: .whitespacesAndNewlines)
		let current = folders(agent)
		guard isFileAccessFolder(entry), !current.contains(entry) else {
			return fileAccess(agent, restricted: restricted(agent), folders: current)
		}
		return fileAccess(agent, restricted: restricted(agent), folders: current + [entry])
	}

	/// Removing the last folder never changes the restriction switch.
	public static func removeFolder(_ agent: [String: JSONValue], _ folder: String) -> [String: JSONValue] {
		fileAccess(agent, restricted: restricted(agent), folders: folders(agent).filter { $0 != folder })
	}

	/// nil removes the explicit pin (automatic activation takes over).
	public static func searchEngine(_ agent: [String: JSONValue], _ engine: String?) -> [String: JSONValue] {
		var next = agent
		if let engine { next["search"] = .object(["engine": .string(engine)]) } else { next["search"] = nil }
		return next
	}

	/// On = explicit true; off = the key removed (absent is the resting state).
	public static func promptSwitch(_ agent: [String: JSONValue], path: String, on: Bool) -> [String: JSONValue] {
		var next = agent
		var prompts = agent["prompts"]?.objectValue ?? [:]
		prompts[path] = on ? .bool(true) : nil
		next["prompts"] = .object(prompts)
		return next
	}

	public static func folders(_ agent: [String: JSONValue]) -> [String] {
		agent["fileAccess"]?["folders"]?.arrayValue?.compactMap(\.stringValue) ?? []
	}

	public static func restricted(_ agent: [String: JSONValue]) -> Bool {
		agent["fileAccess"]?["restricted"]?.boolValue ?? false
	}

	private static func fileAccess(_ agent: [String: JSONValue], restricted: Bool, folders: [String]) -> [String: JSONValue] {
		var next = agent
		next["fileAccess"] = .object(["restricted": .bool(restricted), "folders": .array(folders.map(JSONValue.string))])
		return next
	}
}

/// An allowed-folder entry the server accepts (src/core/file-access.ts).
public func isFileAccessFolder(_ folder: String) -> Bool {
	guard !folder.contains("\0") else { return false }
	if folder == "~" || folder.hasPrefix("~/") || folder.hasPrefix("/") || folder.hasPrefix("\\\\") { return true }
	return folder.prefixMatch(of: /[A-Za-z]:[\\\/]/) != nil
}

/// The three model slots (src/core MODEL_SLOTS) with the web's labels.
public enum ModelSlot: String, Sendable, CaseIterable, Identifiable {
	case strong, cheap, vision

	public var id: String { rawValue }

	public var label: String {
		switch self {
		case .strong: "Strong"
		case .cheap: "Cheap"
		case .vision: "Vision"
		}
	}

	public var roster: String {
		switch self {
		case .strong: "The main model for your sessions"
		case .cheap: "The assistants that research, build demos, and grade your work"
		case .vision: "The assistants that draw and read PDFs"
		}
	}
}

public enum ModelsCompose {
	/// One slot's model/thinking override. Empty model keeps the previous
	/// model; empty thinking drops the level; all empty removes the slot.
	public static func slot(_ models: [String: JSONValue], _ slot: ModelSlot, provider: String, id: String, thinking: String) -> [String: JSONValue] {
		var next = models
		let previous = models[slot.rawValue]
		if provider.isEmpty, id.isEmpty, thinking.isEmpty {
			next[slot.rawValue] = nil
			return next
		}
		var value: [String: JSONValue] = [:]
		if let retention = previous?["cacheRetention"] { value["cacheRetention"] = retention }
		if !provider.isEmpty, !id.isEmpty {
			value["model"] = .object(["provider": .string(provider), "id": .string(id)])
		} else if let model = previous?["model"] {
			value["model"] = model
		}
		if !thinking.isEmpty { value["thinkingLevel"] = .string(thinking) }
		next[slot.rawValue] = .object(value)
		return next
	}

	/// Retention is slot-only; nil (Pi default) removes the field.
	public static func cacheRetention(_ models: [String: JSONValue], _ slot: ModelSlot, _ value: String?) -> [String: JSONValue] {
		var next = models
		var entry = models[slot.rawValue]?.objectValue ?? [:]
		entry["cacheRetention"] = value.map(JSONValue.string)
		next[slot.rawValue] = .object(entry)
		return next
	}
}

/// Pi's cache-retention preference (components/settings/cache-retention-menu.tsx).
public struct CacheRetentionOption: Sendable, Hashable, Identifiable {
	public var value: String?
	public var compact: String
	public var label: String
	public var detail: String
	public var id: String { value ?? "default" }

	public static let all = [
		CacheRetentionOption(value: nil, compact: "default", label: "Pi default", detail: "Leave the option unset. Pi’s normal behavior and environment override apply."),
		CacheRetentionOption(value: "none", compact: "not requested", label: "Don’t request caching", detail: "Pass Pi’s native none preference. Providers may still cache automatically."),
		CacheRetentionOption(value: "short", compact: "short", label: "Short retention", detail: "Pass Pi’s native short preference. The duration depends on the provider and model."),
		CacheRetentionOption(value: "long", compact: "long", label: "Long retention", detail: "Pass Pi’s native long preference. Cache-write costs may be higher."),
	]

	public static func option(for value: String?) -> CacheRetentionOption {
		all.first { $0.value == value } ?? all[0]
	}
}

/// A positive token count clamped up to `floor`; nil for empty input
/// (the factory default) and for anything unparsable or non-positive.
public enum TokenInput {
	public enum Result: Equatable { case unset, value(Int), invalid }

	public static func parse(_ text: String, floor: Int) -> Result {
		let trimmed = text.trimmingCharacters(in: .whitespaces)
		if trimmed.isEmpty { return .unset }
		guard let number = Double(trimmed), number.isFinite, number > 0 else { return .invalid }
		return .value(max(floor, Int(number.rounded())))
	}
}

// MARK: - Provider keys (GET /api/keys, PUT/DELETE /api/keys/:id)

public struct AuthKeyInfo: Sendable, Hashable, Codable {
	public var label: String
	public var docsUrl: String?
}

public struct AuthKeyStatus: Sendable, Hashable, Codable, Identifiable {
	public var id: String
	public var info: AuthKeyInfo?
	public var present: Bool
	public var masked: String?
	/// env | file | none — env always wins and is read-only here.
	public var source: String
	public var shadowedByEnv: Bool?

	public init(id: String, info: AuthKeyInfo? = nil, present: Bool = false, masked: String? = nil, source: String = "none", shadowedByEnv: Bool? = false) {
		self.id = id
		self.info = info
		self.present = present
		self.masked = masked
		self.source = source
		self.shadowedByEnv = shadowedByEnv
	}

	public var envOwned: Bool { source == "env" }
}

/// One pi-ai provider with plain API-key auth.
public struct ProviderKeyInfo: Sendable, Hashable, Codable, Identifiable {
	public var id: String
	public var envVar: String
	public var label: String

	public init(id: String, envVar: String, label: String) {
		self.id = id
		self.envVar = envVar
		self.label = label
	}
}

public struct KeysResponse: Sendable, Hashable, Codable {
	public var keys: [AuthKeyStatus]
	public var providers: [ProviderKeyInfo]?
}

/// The Providers table's grouping (components/settings/keys-section.tsx).
public enum KeyTable {
	/// The curated tool keys (src/core/auth-keys.ts AUTH_KEYS order).
	public static let toolIDs = ["DEEPGRAM_API_KEY", "TAVILY_API_KEY", "BRAVE_API_KEY", "EXA_API_KEY", "FIRECRAWL_API_KEY", "OLLAMA_API_KEY"]
	public static let dictationID = "DEEPGRAM_API_KEY"
	/// The custom endpoint's key lives on its own page, never as a row.
	public static let customEnvVar = "CUSTOM_OPENAI_API_KEY"
	public static let customProvider = ProviderKeyInfo(id: "custom", envVar: "CUSTOM_OPENAI_API_KEY", label: "Custom endpoint")

	public struct Groups: Sendable, Hashable {
		public var providerRows: [AuthKeyStatus]
		public var toolRows: [AuthKeyStatus]
		public var unknownRows: [AuthKeyStatus]
		public var addable: [ProviderKeyInfo]
	}

	public static func classify(_ statuses: [AuthKeyStatus], providers: [ProviderKeyInfo]?) -> Groups {
		let byID = Dictionary(statuses.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
		let providerEnv = Set((providers ?? []).map(\.envVar))
		var providerRows: [AuthKeyStatus] = []
		var unknownRows: [AuthKeyStatus] = []
		for status in statuses {
			if toolIDs.contains(status.id) || status.id == customEnvVar { continue }
			if providerEnv.contains(status.id) || (status.info == nil && providers == nil) { providerRows.append(status) }
			else if status.info == nil { unknownRows.append(status) }
			else { providerRows.append(status) }
		}
		return Groups(
			providerRows: providerRows,
			toolRows: toolIDs.map { byID[$0] ?? AuthKeyStatus(id: $0) },
			unknownRows: unknownRows,
			addable: (providers ?? []).filter { byID[$0.envVar] == nil }
		)
	}

	/// A key row names its credential (OpenCode Zen and Go share one key).
	public static func providerLabel(_ id: String, providers: [ProviderKeyInfo]?) -> String? {
		let matches = providers?.filter { $0.envVar == id } ?? []
		if matches.contains(where: { $0.id == "opencode" }), matches.contains(where: { $0.id == "opencode-go" }) { return "OpenCode (Zen / Go)" }
		return matches.first?.label
	}

	/// "…ab12 · 64" (" · env" marks an environment-owned value).
	public static func statusLine(_ status: AuthKeyStatus) -> String {
		guard status.present, let masked = status.masked else { return "not set" }
		let count = masked.firstMatch(of: /\((\d+) chars\)$/).map { String($0.1) }
		let tail = masked.replacing(/\ \(\d+ chars\)$/, with: "")
		return "\(tail) · \(count ?? "?")\(status.envOwned ? " · env" : "")"
	}
}

extension APIClient {
	public func keyStatuses() async throws -> KeysResponse {
		try await get("/api/keys", as: KeysResponse.self)
	}

	public func saveKey(_ id: String, value: String) async throws {
		try await send(try json("PUT", "/api/keys/\(Self.pathComponent(id))", body: ["value": value]))
	}

	public func deleteKey(_ id: String) async throws {
		try await send(makeRequest("DELETE", "/api/keys/\(Self.pathComponent(id))"))
	}

	static func pathComponent(_ text: String) -> String {
		text.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? text
	}
}

// MARK: - Search (GET /api/search)

public struct SearchStatus: Sendable, Hashable, Codable {
	public var available: Bool
	public var engine: String?
	public var reason: String
}

public struct SearchEngine: Sendable, Hashable, Identifiable {
	public var id: String
	public var label: String
	public var envVar: String

	/// src/core/search.ts SEARCH_ENGINES.
	public static let all = [
		SearchEngine(id: "tavily", label: "Tavily", envVar: "TAVILY_API_KEY"),
		SearchEngine(id: "brave", label: "Brave", envVar: "BRAVE_API_KEY"),
		SearchEngine(id: "exa", label: "Exa", envVar: "EXA_API_KEY"),
		SearchEngine(id: "firecrawl", label: "Firecrawl", envVar: "FIRECRAWL_API_KEY"),
		SearchEngine(id: "ollama", label: "Ollama", envVar: "OLLAMA_API_KEY"),
	]
}

extension APIClient {
	public func searchStatus() async throws -> SearchStatus {
		try await get("/api/search", as: SearchStatus.self)
	}
}

// MARK: - System prompts (GET /api/settings/prompts, PUT/DELETE …/prompts/:path)

public struct PromptSegment: Sendable, Hashable, Codable, Identifiable {
	public var path: String
	public var sourceText: String
	public var overrideText: String?
	public var enabled: Bool
	public var shared: Bool

	public var id: String { path }

	public init(path: String, sourceText: String, overrideText: String?, enabled: Bool, shared: Bool) {
		self.path = path
		self.sourceText = sourceText
		self.overrideText = overrideText
		self.enabled = enabled
		self.shared = shared
	}
}

public struct PromptView: Sendable, Hashable, Codable {
	public var teacher: [PromptSegment]
	public var prober: [PromptSegment]
	public var practice: [PromptSegment]

	public init(teacher: [PromptSegment], prober: [PromptSegment], practice: [PromptSegment]) {
		self.teacher = teacher
		self.prober = prober
		self.practice = practice
	}

	public struct Row: Sendable, Hashable, Identifiable {
		public var segment: PromptSegment
		public var usageHint: String?
		public var id: String { segment.path }
	}

	public struct Section: Sendable, Hashable, Identifiable {
		public var id: String
		public var label: String
		public var rows: [Row]
	}

	/// Teacher, Prober, Practice in assembly order, then Shared listed once
	/// with who uses each chunk (agent-section.tsx sectionedSegments).
	public var sections: [Section] {
		let agents: [(id: String, label: String, segments: [PromptSegment])] = [
			("teacher", "Teacher", teacher), ("prober", "Prober", prober), ("practice", "Practice", practice),
		]
		var shared: [PromptSegment] = []
		for agent in agents {
			for segment in agent.segments where segment.shared && !shared.contains(where: { $0.path == segment.path }) {
				shared.append(segment)
			}
		}
		let own = agents.map { agent in
			Section(id: agent.id, label: agent.label, rows: agent.segments.filter { !$0.shared }.map { Row(segment: $0, usageHint: nil) })
		}
		let sharedRows = shared.map { segment in
			let users = agents.filter { $0.segments.contains { $0.path == segment.path } }.map(\.label)
			let usage = users.count > 1 ? "\(users.dropLast().joined(separator: ", ")) and \(users.last!)" : users.first ?? ""
			return Row(segment: segment, usageHint: "Used by \(usage)")
		}
		return own + [Section(id: "shared", label: "Shared", rows: sharedRows)]
	}
}

/// The line under a row whose override is the version in use.
public let promptInUseHint = "Your version is in use"

extension APIClient {
	public func promptSegments() async throws -> PromptView {
		try await get("/api/settings/prompts", as: PromptView.self)
	}

	public func savePrompt(_ path: String, text: String) async throws {
		try await send(try json("PUT", "/api/settings/prompts/\(Self.promptPath(path))", body: ["text": text]))
	}

	public func deletePrompt(_ path: String) async throws {
		try await send(makeRequest("DELETE", "/api/settings/prompts/\(Self.promptPath(path))"))
	}

	/// The catch-all route takes the segment path as path components.
	static func promptPath(_ path: String) -> String {
		path.split(separator: "/", omittingEmptySubsequences: false).map { pathComponent(String($0)) }.joined(separator: "/")
	}
}

// MARK: - Claude Code (GET /api/claude-code; the switch is the claudeCode section)

public struct ClaudeCodeStatus: Sendable, Hashable, Codable {
	/// not-found | meets-minimum | update-required | version-unchecked
	public var state: String
	public var version: String?
	public var minimumVersion: String

	public var label: String {
		switch state {
		case "not-found": "Not found"
		case "meets-minimum": "Version \(version ?? "?") · meets minimum"
		case "update-required": "Version \(version ?? "?") · update required"
		default: "Version could not be checked"
		}
	}
}

extension APIClient {
	public func claudeCodeStatus() async throws -> ClaudeCodeStatus {
		var request = makeRequest("GET", "/api/claude-code")
		request.setValue("1", forHTTPHeaderField: "x-learnharness-claude-code")
		let (data, _) = try await send(request)
		return try decode(ClaudeCodeStatus.self, from: data)
	}

	/// The server's own origin: the same-origin checks on the subscription,
	/// Claude Code and custom-endpoint controls compare against it.
	public var origin: String {
		var text = connection.baseURL.absoluteString
		while text.hasSuffix("/") { text.removeLast() }
		return text
	}
}
