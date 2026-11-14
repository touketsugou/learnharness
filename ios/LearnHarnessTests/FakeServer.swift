import Foundation
import LHAPI

/// A LearnHarness server in memory: each route answers from a queue of
/// replies (the last one repeats) and every request is recorded. Each server
/// has a host of its own, so tests using different servers run in parallel.
final class FakeServer: @unchecked Sendable {
	struct Request {
		let method: String
		let path: String
		let body: Data

		/// The JSON body.
		var json: JSONValue? { try? JSONDecoder().decode(JSONValue.self, from: body) }
	}

	struct Reply {
		var status = 200
		var body = Data()
		var contentType = "application/json"

		static func json(_ text: String, status: Int = 200) -> Reply { Reply(status: status, body: Data(text.utf8)) }
		static let ok = json("{}")
		static func error(_ status: Int, _ message: String, code: String? = nil) -> Reply {
			var fields: [String: JSONValue] = ["error": .string(message)]
			if let code { fields["code"] = .string(code) }
			return Reply(status: status, body: try! JSONEncoder().encode(JSONValue.object(fields)))
		}
		/// A whole text/event-stream: each frame, then the terminal [DONE].
		static func stream(_ frames: [NativeStreamFrame], done: Bool = true) -> Reply {
			var text = frames.map { "data: \(String(decoding: try! JSONEncoder().encode($0), as: UTF8.self))\n\n" }.joined()
			if done { text += "data: [DONE]\n\n" }
			return Reply(body: Data(text.utf8), contentType: "text/event-stream")
		}
		/// The connection fails (the device is offline).
		static let unreachable = Reply(status: -1)
	}

	let baseURL: URL
	private let lock = NSLock()
	private var routes: [String: [Reply]] = [:]
	/// Routes whose only reply has been given (and repeats until more are queued).
	private var repeating: Set<String> = []
	private var recorded: [Request] = []

	init() {
		baseURL = URL(string: "https://\(UUID().uuidString.lowercased()).fake")!
		Self.registry.withLock { $0[baseURL.host()!] = self }
	}

	deinit {
		let host = baseURL.host()!
		Self.registry.withLock { $0[host] = nil }
	}

	/// Queue replies for "METHOD /path" (no query). A reply already given
	/// stops repeating once new ones are queued.
	func on(_ method: String, _ path: String, _ replies: Reply...) {
		let key = "\(method) \(path)"
		lock.withLock {
			if repeating.remove(key) != nil { routes[key] = [] }
			routes[key, default: []].append(contentsOf: replies)
		}
	}

	var requests: [Request] { lock.withLock { recorded } }

	func requests(_ method: String, _ path: String) -> [Request] {
		requests.filter { $0.method == method && $0.path == path }
	}

	func client() -> APIClient {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [FakeServerProtocol.self]
		return APIClient(connection: ServerConnection(baseURL: baseURL, token: "test-token"), session: URLSession(configuration: configuration))
	}

	/// The next reply for a request; unrouted requests get a 404.
	fileprivate func reply(to request: Request) -> Reply {
		lock.withLock {
			recorded.append(request)
			let key = "\(request.method) \(request.path)"
			guard var queue = routes[key], let first = queue.first else { return .error(404, "No route for \(key)") }
			if queue.count > 1 { queue.removeFirst(); routes[key] = queue } else { repeating.insert(key) }
			return first
		}
	}

	fileprivate static let registry = Locked<[String: FakeServer]>([:])
}

final class Locked<Value>: @unchecked Sendable {
	private let lock = NSLock()
	private var value: Value
	init(_ value: Value) { self.value = value }
	func withLock<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&value) } }
}

final class FakeServerProtocol: URLProtocol {
	override class func canInit(with request: URLRequest) -> Bool { true }
	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

	override func startLoading() {
		guard let url = request.url, let host = url.host(),
			let server = FakeServer.registry.withLock({ $0[host] }) else {
			client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
			return
		}
		let reply = server.reply(to: FakeServer.Request(method: request.httpMethod ?? "GET", path: url.path(), body: Self.body(of: request)))
		guard reply.status > 0 else {
			client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
			return
		}
		let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": reply.contentType])!
		client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
		client?.urlProtocol(self, didLoad: reply.body)
		client?.urlProtocolDidFinishLoading(self)
	}

	override func stopLoading() {}

	/// URLSession hands a protocol the body as a stream.
	private static func body(of request: URLRequest) -> Data {
		if let body = request.httpBody { return body }
		guard let stream = request.httpBodyStream else { return Data() }
		stream.open()
		defer { stream.close() }
		var data = Data()
		var buffer = [UInt8](repeating: 0, count: 4096)
		while stream.hasBytesAvailable {
			let count = stream.read(&buffer, maxLength: buffer.count)
			guard count > 0 else { break }
			data.append(buffer, count: count)
		}
		return data
	}
}
