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
	/// Input modalities ("text", "image").
	public var input: [String]?
	/// USD per 1M tokens; nil when the price is unknown.
	public var cost: ModelCost?

	public var choice: ChatModelChoice { ChatModelChoice(provider: provider, id: id) }

	public var acceptsImages: Bool { input?.contains("image") == true }

	/// The picker's right-hand note (components/settings/model-menu.tsx).
	public var priceLabel: String {
		if provider == "claude-code" { return "CLI billing" }
		if let subscription = SubscriptionProvider.forCatalogProvider(provider) { return subscription.label }
		guard let cost else { return "Unpriced" }
		func format(_ value: Double) -> String {
			var text = String(format: "%.2f", value)
			if value < 1, text.hasSuffix("0") { text.removeLast() }
			return "$" + text
		}
		return "\(format(cost.input))/\(format(cost.output))"
	}
}

public struct ModelCost: Sendable, Hashable, Codable {
	public var input: Double
	public var output: Double
}

/// One slot tier's resolved pin (GET /api/models `slots`).
public struct SlotPin: Sendable, Hashable, Codable {
	public var model: ChatModelChoice
	public var thinkingLevel: String?
	public var cacheRetention: String?
}

public struct CatalogDefaults: Sendable, Hashable, Codable {
	public var model: ChatModelChoice?
	public var thinkingLevel: String?
}

public struct ModelCatalog: Sendable, Hashable, Codable {
	public var models: [ModelCatalogEntry]
	/// The conversation default; nil when no model is configured yet.
	public var defaults: CatalogDefaults?
	/// The three slot tiers' resolved pins (nil per unset tier).
	public var slots: [String: SlotPin?]?

	public func slotPin(_ slot: ModelSlot) -> SlotPin? { slots?[slot.rawValue] ?? nil }

	public func entry(_ provider: String?, _ id: String?) -> ModelCatalogEntry? {
		models.first { $0.provider == provider && $0.id == id }
	}

	/// The vision slot lists image-capable models plus every custom-endpoint
	/// model (the endpoint may not report a modality), image-capable first.
	public func choices(for slot: ModelSlot) -> [ModelCatalogEntry] {
		guard slot == .vision else { return models }
		let eligible = models.filter { $0.acceptsImages || $0.provider == "custom" }
		return eligible.filter(\.acceptsImages) + eligible.filter { !$0.acceptsImages }
	}
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
