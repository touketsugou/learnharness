import Foundation
import Testing
@testable import LHAPI

@Suite("SSE parser")
struct SSEParserTests {
	@Test func parsesNamedEventsCommentsAndCRLF() {
		var parser = SSEParser()
		let wire = ": ping\n\nevent: record-changed\r\ndata: {\"chatId\":\"c1\"}\r\n\r\ndata: a\ndata: b\n\ndata: [DONE]\n\n"
		let events = parser.feed(Array(wire.utf8))
		#expect(events == [
			SSEEvent(event: "record-changed", data: "{\"chatId\":\"c1\"}"),
			SSEEvent(event: nil, data: "a\nb"),
			SSEEvent(event: nil, data: "[DONE]"),
		])
	}

	@Test func holdsPartialEventsAcrossChunks() {
		var parser = SSEParser()
		#expect(parser.feed(Array("data: {\"type\":\"pat".utf8)).isEmpty)
		#expect(parser.feed(Array("ch\"}\n".utf8)).isEmpty)
		#expect(parser.feed(Array("\n".utf8)) == [SSEEvent(data: "{\"type\":\"patch\"}")])
	}

	@Test func keepsMultibyteTextIntact() {
		var parser = SSEParser()
		#expect(parser.feed(Array("data: 学习 ✓\n\n".utf8)) == [SSEEvent(data: "学习 ✓")])
	}
}

@Suite("Requests and errors")
struct RequestTests {
	@Test func normalizesServerAddresses() {
		#expect(ServerConnection.normalizedBaseURL("learn.example.com")?.absoluteString == "https://learn.example.com")
		#expect(ServerConnection.normalizedBaseURL(" http://localhost:3000/chat/x?y=1 ")?.absoluteString == "http://localhost:3000")
		#expect(ServerConnection.normalizedBaseURL("ftp://example.com") == nil)
		#expect(ServerConnection.normalizedBaseURL("") == nil)
	}

	@Test func requestsCarryTheBearerToken() {
		let client = APIClient(connection: ServerConnection(baseURL: URL(string: "https://lh.example")!, token: "secret-token"))
		let request = client.makeRequest("DELETE", "/api/chats/c%201", query: [URLQueryItem(name: "mode", value: "delete-nodes")])
		#expect(request.url?.absoluteString == "https://lh.example/api/chats/c%201?mode=delete-nodes")
		#expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
		#expect(request.httpMethod == "DELETE")
	}

	@Test func mapsServerEnvelopes() {
		func body(_ text: String) -> Data { Data(text.utf8) }
		#expect(APIError.from(status: 401, body: body("{}")) == .unauthorized)
		#expect(APIError.from(status: 409, body: body("{\"error\":\"A turn is already running\"}")) == .conflict("A turn is already running"))
		#expect(APIError.from(status: 503, body: body("{\"error\":\"No model configured\",\"code\":\"models_not_configured\",\"missing\":[\"strong\"]}"))
			== .refused(code: "models_not_configured", message: "No model configured"))
		#expect(APIError.from(status: 400, body: body("plain words")) == .http(status: 400, message: "plain words"))
	}

	@Test func encodesChatInputsLikeTheWebClient() throws {
		func json(_ input: ChatInput) throws -> JSONValue {
			try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(input))
		}
		#expect(try json(.text("hi")) == .object(["type": .string("text"), "text": .string("hi")]))
		#expect(try json(.continue) == .object(["type": .string("continue")]))
		#expect(try json(.retryQuestion(messageId: "m", contentIndex: 2, toolCallId: "t")) == .object([
			"type": .string("retry-question"), "messageId": .string("m"), "contentIndex": .number(2), "toolCallId": .string("t"),
		]))
		#expect(try json(.thinking(problemCallId: "p", text: "x")) == .object(["type": .string("thinking"), "problemCallId": .string("p"), "text": .string("x")]))
	}

	@Test func quotesPathsLikeDesktopAttachments() {
		// Same cases as tests/file-paths.test.ts.
		#expect(FilePathQuoting.quote("/data/uploads/a.pdf") == "`/data/uploads/a.pdf`")
		#expect(FilePathQuoting.quote("/tmp/a`b.txt") == "``/tmp/a`b.txt``")
		#expect(FilePathQuoting.quote("/tmp/a`") == "`` /tmp/a` ``")
		#expect(FilePathQuoting.quote("/tmp/a```") == "```` /tmp/a``` ````")
	}
}

/// Answers every request with a 401.
private final class UnauthorizedProtocol: URLProtocol {
	override class func canInit(with request: URLRequest) -> Bool { true }
	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
	override func startLoading() {
		let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
		client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
		client?.urlProtocol(self, didLoad: Data("{\"error\":\"Unauthorized\"}".utf8))
		client?.urlProtocolDidFinishLoading(self)
	}
	override func stopLoading() {}
}

private final class Counter: @unchecked Sendable {
	private let lock = NSLock()
	private var count = 0
	func increment() { lock.withLock { count += 1 } }
	var value: Int { lock.withLock { count } }
}

@Suite("Rejected token")
struct UnauthorizedTests {
	private func client(_ counter: Counter) -> APIClient {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [UnauthorizedProtocol.self]
		return APIClient(connection: ServerConnection(baseURL: URL(string: "https://lh.example")!, token: "old"),
			session: URLSession(configuration: configuration), onUnauthorized: { counter.increment() })
	}

	@Test func requestsReportA401() async {
		let counter = Counter()
		await #expect(throws: APIError.unauthorized) { try await client(counter).verifyConnection() }
		#expect(counter.value == 1)
	}

	@Test func streamsReportA401() async {
		let counter = Counter()
		await #expect(throws: APIError.unauthorized) { for try await _ in client(counter).events("/api/events") {} }
		#expect(counter.value == 1)
	}
}
