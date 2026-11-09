import Foundation

/// HTTP access to one LearnHarness cloud server. Every request carries the
/// Bearer token; no cookies are stored.
public final class APIClient: Sendable {
	public let connection: ServerConnection
	private let session: URLSession
	/// Called on every 401 (request or stream) before the error is thrown.
	private let onUnauthorized: (@Sendable () -> Void)?

	public static func makeSession() -> URLSession {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.httpCookieStorage = nil
		configuration.httpShouldSetCookies = false
		configuration.urlCache = nil
		configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
		configuration.timeoutIntervalForRequest = 60
		configuration.waitsForConnectivity = false
		return URLSession(configuration: configuration)
	}

	public init(connection: ServerConnection, session: URLSession = APIClient.makeSession(), onUnauthorized: (@Sendable () -> Void)? = nil) {
		self.connection = connection
		self.session = session
		self.onUnauthorized = onUnauthorized
	}

	// MARK: Requests

	public func makeRequest(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil, contentType: String? = nil) -> URLRequest {
		var components = URLComponents(url: connection.baseURL, resolvingAgainstBaseURL: false)!
		components.percentEncodedPath = path
		if !query.isEmpty { components.queryItems = query }
		var request = URLRequest(url: components.url!)
		request.httpMethod = method
		request.httpBody = body
		request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
		if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
		return request
	}

	/// Perform a request; non-2xx statuses throw APIError.
	@discardableResult
	public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
		let data: Data
		let response: URLResponse
		do {
			(data, response) = try await session.data(for: request)
		} catch is CancellationError {
			throw CancellationError()
		} catch let error as URLError where error.code == .cancelled {
			throw CancellationError()
		} catch {
			throw APIError.transport(error.localizedDescription)
		}
		guard let http = response as? HTTPURLResponse else { throw APIError.transport("No HTTP response.") }
		guard (200..<300).contains(http.statusCode) else {
			if http.statusCode == 401 { onUnauthorized?() }
			throw APIError.from(status: http.statusCode, body: data)
		}
		return (data, http)
	}

	public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
		do { return try JSONDecoder().decode(T.self, from: data) }
		catch { throw APIError.decoding(String(describing: error)) }
	}

	public func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], as type: T.Type) async throws -> T {
		let (data, _) = try await send(makeRequest("GET", path, query: query))
		return try decode(T.self, from: data)
	}

	public func json<B: Encodable>(_ method: String, _ path: String, body: B, query: [URLQueryItem] = []) throws -> URLRequest {
		let data: Data
		do { data = try JSONEncoder().encode(body) }
		catch { throw APIError.decoding(String(describing: error)) }
		return makeRequest(method, path, query: query, body: data, contentType: "application/json")
	}

	// MARK: Streams

	/// A server-sent event stream. Ends when the server closes; cancelling
	/// the consuming task closes the connection.
	public func events(_ path: String, timeout: TimeInterval = 600) -> AsyncThrowingStream<SSEEvent, any Error> {
		let request: URLRequest = {
			var request = makeRequest("GET", path)
			request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
			request.timeoutInterval = timeout
			return request
		}()
		let session = self.session
		let onUnauthorized = self.onUnauthorized
		return AsyncThrowingStream { continuation in
			let task = Task {
				do {
					let (bytes, response) = try await session.bytes(for: request)
					guard let http = response as? HTTPURLResponse else { throw APIError.transport("No HTTP response.") }
					guard (200..<300).contains(http.statusCode) else {
						if http.statusCode == 401 { onUnauthorized?() }
						var body = Data()
						for try await byte in bytes { body.append(byte); if body.count > 65_536 { break } }
						throw APIError.from(status: http.statusCode, body: body)
					}
					var parser = SSEParser()
					for try await byte in bytes {
						if let event = parser.feed(byte) { continuation.yield(event) }
					}
					continuation.finish()
				} catch is CancellationError {
					continuation.finish()
				} catch let error as URLError where error.code == .cancelled {
					continuation.finish()
				} catch let error as APIError {
					continuation.finish(throwing: error)
				} catch {
					continuation.finish(throwing: APIError.transport(error.localizedDescription))
				}
			}
			continuation.onTermination = { _ in task.cancel() }
		}
	}
}
