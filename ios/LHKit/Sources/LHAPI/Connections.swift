import Foundation

// MARK: - Custom endpoint (GET/POST/PATCH/DELETE /api/custom-provider)

public struct CustomModel: Sendable, Hashable, Codable, Identifiable {
	public var id: String
	public var image: Bool?
	public var reasoning: Bool?
	public var context: Int?
	public var maxTokens: Int?

	public init(id: String, image: Bool? = nil, reasoning: Bool? = nil, context: Int? = nil, maxTokens: Int? = nil) {
		self.id = id
		self.image = image
		self.reasoning = reasoning
		self.context = context
		self.maxTokens = maxTokens
	}
}

/// A user pin for one discovered model; absent fields fall back to the
/// endpoint's reported value, then the compiled default.
public struct CustomModelOverride: Sendable, Hashable, Codable {
	public var context: Int?
	public var maxTokens: Int?
	public var reasoning: Bool?

	public init(context: Int? = nil, maxTokens: Int? = nil, reasoning: Bool? = nil) {
		self.context = context
		self.maxTokens = maxTokens
		self.reasoning = reasoning
	}

	var isEmpty: Bool { context == nil && maxTokens == nil && reasoning == nil }
}

/// The endpoint's non-secret status; `revision` is the ETag every write
/// must echo in If-Match.
public struct CustomProviderStatus: Sendable, Hashable {
	public static let defaultContextWindow = 8192
	public static let defaultMaxTokens = 4096

	public var keyReuseRequired: Bool
	public var revision: String
	/// keyless | apiKey
	public var authMode: String
	/// env | file | none
	public var keySource: String
	public var baseUrl: String
	public var models: [CustomModel]
	public var overrides: [String: CustomModelOverride]
	public var manualModels: [String]
	public var keyPresent: Bool

	public var isConfigured: Bool { !baseUrl.trimmingCharacters(in: .whitespaces).isEmpty }

	/// "http://host/v1 · 3 models · API key".
	public var summary: String {
		let count = models.count
		let auth = authMode == "keyless" ? "keyless" : keyPresent ? "API key" : "API key missing"
		return "\(baseUrl) · \(count) model\(count == 1 ? "" : "s") · \(auth)"
	}

	init(reply: JSONValue, revision: String) {
		self.revision = revision
		keyReuseRequired = reply["keyReuseRequired"]?.boolValue ?? false
		authMode = reply["authMode"]?.stringValue ?? "keyless"
		keySource = reply["keySource"]?.stringValue ?? "none"
		baseUrl = reply["baseUrl"]?.stringValue ?? ""
		models = (try? reply["models"]?.decode([CustomModel].self)) ?? []
		overrides = (try? reply["overrides"]?.decode([String: CustomModelOverride].self)) ?? [:]
		manualModels = reply["manualModels"]?.arrayValue?.compactMap(\.stringValue) ?? []
		keyPresent = reply["keyPresent"]?.boolValue ?? false
	}
}

/// One model's pin form: "" means no pin; reasoning is "", "on" or "off".
public struct CustomPinDraft: Sendable, Hashable {
	public var context: String
	public var maxTokens: String
	public var reasoning: String

	public init(_ pin: CustomModelOverride?) {
		context = pin?.context.map(String.init) ?? ""
		maxTokens = pin?.maxTokens.map(String.init) ?? ""
		reasoning = pin?.reasoning.map { $0 ? "on" : "off" } ?? ""
	}

	/// Drafts → the replace-whole PATCH payload: blank fields send nothing
	/// and a fully blank model is absent (that IS the un-pin).
	public static func payload(_ drafts: [String: CustomPinDraft]) -> [String: CustomModelOverride] {
		var out: [String: CustomModelOverride] = [:]
		for (id, draft) in drafts {
			var pin = CustomModelOverride()
			if let value = Int(draft.context.trimmingCharacters(in: .whitespaces)) { pin.context = value }
			if let value = Int(draft.maxTokens.trimmingCharacters(in: .whitespaces)) { pin.maxTokens = value }
			if !draft.reasoning.isEmpty { pin.reasoning = draft.reasoning == "on" }
			if !pin.isEmpty { out[id] = pin }
		}
		return out
	}

	public static func drafts(_ models: [CustomModel], _ overrides: [String: CustomModelOverride]) -> [String: CustomPinDraft] {
		Dictionary(models.map { ($0.id, CustomPinDraft(overrides[$0.id])) }, uniquingKeysWith: { first, _ in first })
	}
}

/// What Connect sends (the key only when typed, never an env-owned one).
public struct CustomConnectRequest: Sendable, Encodable {
	public var baseUrl: String
	public var authMode: String
	public var reuseKey: Bool
	public var manualModels: String
	public var key: String?

	public init(baseUrl: String, authMode: String, reuseKey: Bool, manualModels: String, key: String?) {
		self.baseUrl = baseUrl
		self.authMode = authMode
		self.reuseKey = reuseKey
		self.manualModels = manualModels
		self.key = key
	}
}

/// The web's URL comparison (src/core normalizeBaseUrl): trimmed, no trailing slashes.
public func normalizedEndpointURL(_ text: String) -> String {
	var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
	while value.hasSuffix("/") { value.removeLast() }
	return value
}

extension APIClient {
	/// `inspectKey` asks for the effective API-key state (`?authMode=apiKey`).
	public func customProvider(inspectKey: Bool = false) async throws -> CustomProviderStatus {
		let query = inspectKey ? [URLQueryItem(name: "authMode", value: "apiKey")] : []
		let (data, response) = try await send(makeRequest("GET", "/api/custom-provider", query: query))
		return CustomProviderStatus(reply: try decode(JSONValue.self, from: data), revision: response.value(forHTTPHeaderField: "etag") ?? "")
	}

	public func connectCustomProvider(_ body: CustomConnectRequest, revision: String) async throws {
		try await send(try sameOrigin(json("POST", "/api/custom-provider", body: body), revision: revision))
	}

	/// Save the per-model pins; returns the stored map and the new revision.
	public func saveCustomPins(_ overrides: [String: CustomModelOverride], revision: String) async throws -> (overrides: [String: CustomModelOverride], revision: String) {
		let (data, response) = try await send(try sameOrigin(json("PATCH", "/api/custom-provider", body: ["overrides": overrides]), revision: revision))
		let stored = (try? decode(JSONValue.self, from: data))?["overrides"].flatMap { try? $0.decode([String: CustomModelOverride].self) }
		return (stored ?? overrides, response.value(forHTTPHeaderField: "etag") ?? revision)
	}

	public func disconnectCustomProvider(revision: String) async throws {
		try await send(try sameOrigin(json("DELETE", "/api/custom-provider", body: [String: String]()), revision: revision))
	}

	private func sameOrigin(_ request: URLRequest, revision: String) -> URLRequest {
		var request = request
		request.setValue(origin, forHTTPHeaderField: "Origin")
		request.setValue(revision, forHTTPHeaderField: "If-Match")
		return request
	}
}

// MARK: - Subscriptions: GitHub Copilot and Grok sign-in (/api/subscriptions)

public struct SubscriptionPrompt: Sendable, Hashable, Codable {
	public struct Option: Sendable, Hashable, Codable, Identifiable {
		public var id: String
		public var label: String
		public var description: String?
	}

	public var id: String
	/// text | secret | select | manual_code
	public var type: String
	public var message: String
	public var placeholder: String?
	public var options: [Option]?
}

public struct SubscriptionInteraction: Sendable, Hashable, Codable {
	public struct Browser: Sendable, Hashable, Codable {
		public var id: String
	}

	public var attemptId: String
	public var prompt: SubscriptionPrompt?
	public var browser: Browser?
	public var userCode: String?
	public var progress: String?
}

public struct SubscriptionStatus: Sendable, Hashable, Codable, Identifiable {
	public var providerId: String
	public var available: Bool
	public var connected: Bool
	public var pending: Bool
	public var committing: Bool?
	public var allowBackgroundUse: Bool
	public var connectionId: String?
	public var revision: Int
	public var error: String?
	public var interaction: SubscriptionInteraction?

	public var id: String { providerId }

	public init(empty providerId: String) {
		self.providerId = providerId
		available = false
		connected = false
		pending = false
		allowBackgroundUse = true
		revision = 0
	}
}

/// The subscription providers (src/core/contracts/subscriptions.ts) and
/// the web's copy for a server-hosted connection.
public struct SubscriptionProvider: Sendable, Hashable, Identifiable {
	public var providerId: String
	/// The catalog provider id its models carry.
	public var logicalId: String
	public var label: String
	public var id: String { providerId }

	public static let all = [
		SubscriptionProvider(providerId: "github-copilot", logicalId: "github-copilot-subscription", label: "GitHub Copilot"),
		SubscriptionProvider(providerId: "xai", logicalId: "xai-subscription", label: "Grok"),
	]

	public static func forCatalogProvider(_ provider: String?) -> SubscriptionProvider? {
		all.first { $0.logicalId == provider }
	}

	public static let copilotPolicyNotice = "Pi's native Copilot sign-in may enable additional models whose policy is not yet configured. Models explicitly disabled by policy are not enabled. Organization restrictions still apply."
	public static let backgroundHint = "Allow LearnHarness helper agents and automatic follow-ups to use this connection."

	public var notice: String {
		"Your prompts, tool results, and relevant session context are sent to \(label) to run the work you select. Credentials are stored on the machine running LearnHarness in an owner-only plaintext file. Provider terms, data-use policies, and plan limits apply. This connection never falls back to an API key."
	}

	public var disconnectCopy: String {
		"Disconnect \(label) from LearnHarness? This stops work using this connection and removes its saved credentials from the machine running LearnHarness. It does not cancel your subscription or revoke access at the provider. Saved model choices will remain unavailable until you reconnect or change them."
	}
}

extension APIClient {
	public func subscriptionStatuses() async throws -> [SubscriptionStatus] {
		let (data, _) = try await send(subscriptionRequest("GET", "/api/subscriptions"))
		return try decode(JSONValue.self, from: data)["native"].flatMap { try? $0.decode([SubscriptionStatus].self) } ?? []
	}

	/// One control op (login, cancel, respond, open, retry, disconnect,
	/// consent); returns the one-use browser action path when there is one.
	@discardableResult
	public func subscriptionControl(_ providerId: String, op: String, fields: [String: JSONValue] = [:], timeout: TimeInterval? = nil) async throws -> String? {
		var body = fields
		body["providerId"] = .string(providerId)
		body["op"] = .string(op)
		var request = subscriptionRequest("POST", "/api/subscriptions")
		// login answers only when sign-in completes.
		if let timeout { request.timeoutInterval = timeout }
		request.httpBody = try JSONEncoder().encode(JSONValue.object(body))
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		let (data, _) = try await send(request)
		return (try? decode(JSONValue.self, from: data))?["browserAction"]?.stringValue
	}

	/// Resolve a one-use browser action to the provider's sign-in page: the
	/// server answers 303 with the target, which must not be followed here.
	public func subscriptionBrowserTarget(_ action: String) async throws -> URL {
		guard action.wholeMatch(of: /\/api\/subscriptions\/browser\?id=[0-9a-f-]{36}/) != nil,
			let id = action.split(separator: "=").last
		else { throw APIError.decoding("Invalid sign-in action.") }
		let request = subscriptionRequest("POST", "/api/subscriptions/browser", query: [URLQueryItem(name: "id", value: String(id))])
		let response: URLResponse
		let data: Data
		do {
			(data, response) = try await URLSession.shared.data(for: request, delegate: NoRedirects())
		} catch {
			throw APIError.transport(error.localizedDescription)
		}
		guard let http = response as? HTTPURLResponse else { throw APIError.transport("No HTTP response.") }
		guard http.statusCode == 303, let location = http.value(forHTTPHeaderField: "Location"),
			let url = URL(string: location), url.scheme == "https"
		else { throw (200..<300).contains(http.statusCode) ? APIError.decoding("No sign-in page.") : APIError.from(status: http.statusCode, body: data) }
		return url
	}

	private func subscriptionRequest(_ method: String, _ path: String, query: [URLQueryItem] = []) -> URLRequest {
		var request = makeRequest(method, path, query: query)
		request.setValue("1", forHTTPHeaderField: "x-learnharness-subscriptions")
		request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
		if method != "GET" { request.setValue(origin, forHTTPHeaderField: "Origin") }
		return request
	}
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
	func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
		nil
	}
}
