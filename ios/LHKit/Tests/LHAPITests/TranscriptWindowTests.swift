import Foundation
import Testing
@testable import LHAPI

@Suite("Transcript window")
struct TranscriptWindowTests {
	func parts(_ count: Int, _ prefix: String) -> [NativeViewPart] {
		(0..<count).map { NativeViewPart(fields: ["type": .string("text"), "id": .string("\(prefix)-\($0)")]) }
	}

	/// 10 + 2 + 40 + 1 + 5 = 58 parts.
	var messages: [NativeViewMessage] {
		[
			NativeViewMessage(id: "a0", role: .assistant, parts: parts(10, "a0")),
			NativeViewMessage(id: "u1", role: .user, parts: parts(2, "u1")),
			NativeViewMessage(id: "a2", role: .assistant, parts: parts(40, "a2")),
			NativeViewMessage(id: "u3", role: .user, parts: parts(1, "u3")),
			NativeViewMessage(id: "a4", role: .assistant, parts: parts(5, "a4")),
		]
	}

	@Test func opensOnTheLastPage() {
		#expect(TranscriptWindow.partCount(in: messages) == 58)
		#expect(TranscriptWindow.opening(messages) == 28)
		#expect(TranscriptWindow.start(hiding: 28, in: messages) == .init(message: 2, part: 16, hiddenParts: 28))
	}

	@Test func aShortTranscriptHidesNothing() {
		let short = Array(messages.prefix(2))
		#expect(TranscriptWindow.opening(short) == 0)
		#expect(TranscriptWindow.start(hiding: 0, in: short) == .init(message: 0, part: 0, hiddenParts: 0))
	}

	@Test func aLearnerMessageShowsWhole() {
		// Hiding 11 would cut u1 after its first part.
		#expect(TranscriptWindow.start(hiding: 11, in: messages) == .init(message: 1, part: 0, hiddenParts: 10))
		#expect(TranscriptWindow.start(hiding: 12, in: messages) == .init(message: 2, part: 0, hiddenParts: 12))
	}

	@Test func theLastPageAlwaysShows() {
		// More hidden than a shorter transcript allows.
		#expect(TranscriptWindow.start(hiding: 50, in: messages) == .init(message: 2, part: 16, hiddenParts: 28))
	}

	@Test func partsBeforeAPart() {
		#expect(TranscriptWindow.partsBefore(partID: "a0-0", in: messages) == 0)
		#expect(TranscriptWindow.partsBefore(partID: "a2-3", in: messages) == 15)
		#expect(TranscriptWindow.partsBefore(partID: "nope", in: messages) == nil)
	}
}
