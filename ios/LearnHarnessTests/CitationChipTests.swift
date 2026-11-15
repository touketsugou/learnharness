import Foundation
import LHAPI
import Testing
@testable import LearnHarness

@Suite("Tutor quote chips")
struct CitationChipTests {
	/// The server's own projection (tests/fixtures/native/citations.view.json):
	/// its UTF-16 ranges must cut the Swift string where the links are.
	private static func quotingMessage() throws -> NativeViewMessage {
		let url = URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
			.appending(path: "tests/fixtures/native/citations.view.json")
		let view = try JSONDecoder().decode(NativeSessionView.self, from: Data(contentsOf: url))
		return try #require(view.messages.first { $0.id == "msg_user_quoting" })
	}

	private static func links(_ text: AttributedString) -> [URL] {
		text.runs.compactMap(\.link)
	}

	@Test func theServersRangesBecomeChipsAcrossCJKAndEmoji() throws {
		let text = UserText.attributed(try Self.quotingMessage().parts)
		#expect(String(text.characters) == "这里没懂：❝ 为什么要先归一化 还有 😀 ❝ 我不懂这里 🤔")
		#expect(Self.links(text).map(UserText.messageId(from:)) == ["msg_tutor_quoted", "msg_tutor_quoted"])
	}

	@Test func aRangeThatDoesNotFitStaysText() {
		let text = "abc [link] def"
		let outside: JSONValue = .object(["start": .number(4), "end": .number(99), "label": .string("x"), "messageId": .string("m")])
		#expect(String(UserText.attributed(text: text, citations: [outside]).characters) == text)
		// Overlapping the previous chip: kept as text after it.
		let first: JSONValue = .object(["start": .number(4), "end": .number(10), "label": .string("one"), "messageId": .string("m1")])
		let overlapping: JSONValue = .object(["start": .number(6), "end": .number(14), "label": .string("two"), "messageId": .string("m2")])
		#expect(String(UserText.attributed(text: text, citations: [first, overlapping]).characters) == "abc ❝ one def")
	}

	@Test func aRangeInsideACharacterStaysText() {
		// 😀 is two UTF-16 units; a range starting between them is not a character boundary.
		let text = "😀 tail"
		let split: JSONValue = .object(["start": .number(1), "end": .number(4), "label": .string("x"), "messageId": .string("m")])
		#expect(String(UserText.attributed(text: text, citations: [split]).characters) == text)
	}

	@Test func otherLinksAreNotQuotes() {
		#expect(UserText.messageId(from: URL(string: "https://example.com/chat/x")!) == nil)
		#expect(UserText.messageId(from: URL(string: "lh-citation-focus:")!) == nil)
	}

	@Test func filePathsStillBecomeFileChipsAroundAQuote() {
		let text = "`/data/uploads/2026-11/e2691eb5-05f7-4ba5-b1a6-d0268d654d94-notes.md` [q]"
		let quote: JSONValue = .object(["start": .number(70), "end": .number(73), "label": .string("why"), "messageId": .string("m")])
		#expect(String(UserText.attributed(text: text, citations: [quote]).characters) == "📎 notes.md ❝ why")
	}
}
