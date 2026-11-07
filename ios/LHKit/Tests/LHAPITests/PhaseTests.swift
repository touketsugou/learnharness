import Foundation
import Testing
@testable import LHAPI

@Suite("Transcript phases")
struct PhaseTests {
	func part(_ fields: [String: JSONValue]) -> NativeViewPart { NativeViewPart(fields: fields) }
	let step = NativeViewPart(fields: ["type": .string("step-start")])
	var tagged: NativeViewPart { part(["type": .string("tool-quiz"), "input": .object(["nodeId": .string("n1")])]) }
	var probeDone: NativeViewPart { part(["type": .string("tool-probe_done"), "state": .string("output-available"), "output": .object(["ok": .bool(true)])]) }

	@Test func dividerBeforeAMessageWhoseFirstStepTeaches() {
		let messages = [
			NativeViewMessage(id: "u", role: .user, parts: [part(["type": .string("text"), "text": .string("hi")])]),
			NativeViewMessage(id: "a1", role: .assistant, parts: [step, probeDone]),
			NativeViewMessage(id: "a2", role: .assistant, parts: [step, tagged]),
		]
		#expect(TranscriptPhases.teachDivider(in: messages) == .init(messageIndex: 2, partIndex: nil))
	}

	@Test func dividerAtALaterStepBoundary() {
		let messages = [
			NativeViewMessage(id: "u", role: .user, parts: []),
			NativeViewMessage(id: "a", role: .assistant, parts: [step, probeDone, step, part(["type": .string("text")]), step, tagged]),
		]
		#expect(TranscriptPhases.teachDivider(in: messages) == .init(messageIndex: 1, partIndex: 4))
	}

	@Test func noDividerWithoutTheProbeHandoffOrATag() {
		let untagged = part(["type": .string("tool-quiz"), "input": .object([:])])
		#expect(TranscriptPhases.teachDivider(in: [NativeViewMessage(id: "a", role: .assistant, parts: [step, tagged])]) == nil)
		#expect(TranscriptPhases.teachDivider(in: [
			NativeViewMessage(id: "u", role: .user, parts: []),
			NativeViewMessage(id: "a", role: .assistant, parts: [step, probeDone, untagged]),
		]) == nil)
	}

	@Test func realTeachingFixtureHasOneDivider() throws {
		let name = try #require(Fixtures.viewNames.first { name in
			(try? JSONDecoder().decode(NativeSessionView.self, from: Fixtures.data(name)))?.state.phase == .teach
		})
		let view = try JSONDecoder().decode(NativeSessionView.self, from: Fixtures.data(name))
		let divider = try #require(TranscriptPhases.teachDivider(in: view.messages))
		#expect(view.messages[divider.messageIndex].role == .assistant)
	}
}
