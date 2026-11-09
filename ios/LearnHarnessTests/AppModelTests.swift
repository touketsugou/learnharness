import Foundation
import LHAPI
import Testing
@testable import LearnHarness

/// In-memory token store for tests.
final class MemoryTokenStore: TokenStore, @unchecked Sendable {
	var token: String?
	func read() -> String? { token }
	func save(_ token: String) throws { self.token = token }
	func delete() { token = nil }
}

@MainActor
@Suite("App model")
struct AppModelTests {
	func defaults() -> UserDefaults {
		let name = "lh-tests-\(UUID().uuidString)"
		return UserDefaults(suiteName: name)!
	}

	@Test func restoresASavedServer() {
		let defaults = defaults()
		defaults.set("https://learn.example.com", forKey: "serverURL")
		let tokens = MemoryTokenStore()
		tokens.token = "t"
		let model = AppModel(tokens: tokens, defaults: defaults)
		#expect(model.connection == ServerConnection(baseURL: URL(string: "https://learn.example.com")!, token: "t"))
		#expect(model.client != nil)
	}

	@Test func staysSignedOutWithoutAToken() {
		let defaults = defaults()
		defaults.set("https://learn.example.com", forKey: "serverURL")
		#expect(AppModel(tokens: MemoryTokenStore(), defaults: defaults).client == nil)
	}

	@Test func rejectsBadInputBeforeAnyRequest() async {
		let model = AppModel(tokens: MemoryTokenStore(), defaults: defaults())
		await #expect(throws: ConnectionError.self) { try await model.connect(address: "ftp://x", token: "t") }
		await #expect(throws: ConnectionError.self) { try await model.connect(address: "learn.example.com", token: "  ") }
	}

	@Test func signOutForgetsTheServer() async {
		let defaults = defaults()
		defaults.set("https://learn.example.com", forKey: "serverURL")
		let tokens = MemoryTokenStore()
		tokens.token = "t"
		let model = AppModel(tokens: tokens, defaults: defaults)
		await model.signOut()
		#expect(model.client == nil)
		#expect(tokens.token == nil)
		#expect(defaults.string(forKey: "serverURL") == nil)
	}

	@Test func aRejectedTokenAsksForANewOneAndKeepsTheServer() {
		let defaults = defaults()
		defaults.set("https://learn.example.com", forKey: "serverURL")
		let tokens = MemoryTokenStore()
		tokens.token = "t"
		let model = AppModel(tokens: tokens, defaults: defaults)
		model.tokenRejected(model.connection!)
		#expect(model.client == nil)
		#expect(model.tokenWasRejected)
		#expect(model.store != nil)
		#expect(tokens.token == "t")
		#expect(model.serverAddress == "https://learn.example.com")
	}

	@Test func aLateRejectionOfAReplacedConnectionIsIgnored() {
		let defaults = defaults()
		defaults.set("https://learn.example.com", forKey: "serverURL")
		let tokens = MemoryTokenStore()
		tokens.token = "new"
		let model = AppModel(tokens: tokens, defaults: defaults)
		model.tokenRejected(ServerConnection(baseURL: URL(string: "https://learn.example.com")!, token: "old"))
		#expect(model.client != nil)
		#expect(!model.tokenWasRejected)
	}

	@Test func signOutAfterARejectionStartsOver() async {
		let defaults = defaults()
		defaults.set("https://learn.example.com", forKey: "serverURL")
		let tokens = MemoryTokenStore()
		tokens.token = "t"
		let model = AppModel(tokens: tokens, defaults: defaults)
		model.tokenRejected(model.connection!)
		await model.signOut()
		#expect(!model.tokenWasRejected)
		#expect(model.store == nil)
		#expect(tokens.token == nil)
	}

	@Test func keychainRoundTrip() throws {
		let store = KeychainTokenStore(service: "lh-tests-\(UUID().uuidString)")
		try store.save("secret")
		#expect(store.read() == "secret")
		try store.save("rotated")
		#expect(store.read() == "rotated")
		store.delete()
		#expect(store.read() == nil)
	}
}
