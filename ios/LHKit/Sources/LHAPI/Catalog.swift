import Foundation

// GET /api/models (src/core/contracts/models.ts ModelCatalogResponse).

public struct ModelCatalogEntry: Sendable, Hashable, Codable, Identifiable {
	public var id: String
	public var name: String
	public var provider: String
	public var reasoning: Bool
	/// The thinking levels this model accepts (the picker lists exactly these).
	public var supportedLevels: [String]
	public var contextWindow: Int?

	public var choice: ChatModelChoice { ChatModelChoice(provider: provider, id: id) }
}

public struct CatalogDefaults: Sendable, Hashable, Codable {
	public var model: ChatModelChoice?
	public var thinkingLevel: String?
}

public struct ModelCatalog: Sendable, Hashable, Codable {
	public var models: [ModelCatalogEntry]
	/// The conversation default; nil when no model is configured yet.
	public var defaults: CatalogDefaults?
}

extension APIClient {
	public func modelCatalog() async throws -> ModelCatalog {
		try await get("/api/models", as: ModelCatalog.self)
	}

	/// Replace-whole per-session model choice (absent fields = default).
	@discardableResult
	public func updateChatSettings(_ chatId: String, _ settings: ChatSettings) async throws -> ChatSettings {
		struct Response: Decodable { var settings: ChatSettings }
		let path = "/api/chats/\(chatId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? chatId)/settings"
		let (data, _) = try await send(try json("PUT", path, body: settings))
		return try decode(Response.self, from: data).settings
	}
}

/// Thinking-level rules the web picker applies client-side
/// (components/thinking-default.ts over src/core DEFAULT_THINKING_ORDER).
public enum ThinkingLevels {
	public static let defaultOrder = ["medium", "low", "high", "minimal", "xhigh", "max"]

	/// The level a fresh pick of a model with `supported` levels populates.
	public static func defaultLevel(_ supported: [String]) -> String {
		defaultOrder.first(where: supported.contains) ?? supported.first ?? "off"
	}

	/// A model pick keeps an explicit stored level (the server clamps it),
	/// otherwise populates the default for the new model.
	public static func populate(_ explicit: String?, supported: [String]) -> String {
		explicit ?? defaultLevel(supported)
	}
}

/// The web's short model label (components/usage-format.ts prettyModel).
public func prettyModelName(_ id: String) -> String {
	guard let slash = id.lastIndex(of: "/") else { return id }
	return String(id[id.index(after: slash)...])
}
