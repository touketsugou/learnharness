import Foundation
import Security

/// Where the server access token lives.
protocol TokenStore: Sendable {
	func read() -> String?
	func save(_ token: String) throws
	func delete()
}

/// The token in the Keychain: this device only, available after first unlock.
struct KeychainTokenStore: TokenStore {
	var service = (Bundle.main.bundleIdentifier ?? "learnharness") + ".server-token"
	var account = "default"

	private var query: [String: Any] {
		[kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
	}

	func read() -> String? {
		var query = query
		query[kSecReturnData as String] = true
		query[kSecMatchLimit as String] = kSecMatchLimitOne
		var item: CFTypeRef?
		guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
		return String(data: data, encoding: .utf8)
	}

	func save(_ token: String) throws {
		delete()
		var attributes = query
		attributes[kSecValueData as String] = Data(token.utf8)
		attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
		let status = SecItemAdd(attributes as CFDictionary, nil)
		guard status == errSecSuccess else { throw KeychainError(status: status) }
	}

	func delete() {
		SecItemDelete(query as CFDictionary)
	}
}

struct KeychainError: LocalizedError {
	let status: OSStatus
	var errorDescription: String? { "The token could not be saved to the Keychain (\(status))." }
}
