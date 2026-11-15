import LHAPI
import Testing
@testable import LearnHarness

@Suite("Transcript parts")
struct TranscriptPartTests {
	private func part(_ fields: [String: JSONValue]) -> NativeViewPart {
		NativeViewPart(fields: fields)
	}

	@Test func aFailedToolCallIsARetry() {
		#expect(part(["type": .string("tool-read"), "state": .string("output-error"), "errorText": .string("ENOENT")]).isAgentRetry)
	}

	@Test func anAbortedCallIsNot() {
		#expect(!part(["type": .string("tool-read"), "state": .string("output-error"), "errorText": .string("Operation aborted")]).isAgentRetry)
	}

	@Test func anUnreadablePluginQuestionIsNot() {
		let unreadable = part([
			"type": .string("tool-coding_check"), "state": .string("output-error"),
			"pluginQuestion": .object(["status": .string("unreadable")]),
		])
		#expect(!unreadable.isAgentRetry)
	}
}
