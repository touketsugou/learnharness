import Foundation
import Testing
@testable import LHAPI

@Suite("Dictation helpers")
struct DictationTests {
	@Test func appendMatchesTheWebJoinRule() {
		#expect(DraftText.append("world", to: "") == "world")
		#expect(DraftText.append("world", to: "hello") == "hello world")
		#expect(DraftText.append("world", to: "hello \n ") == "hello world")
		#expect(DraftText.append("", to: "hello ") == "hello ")
		#expect(DraftText.append("x", to: "   ") == "x")
	}

	@Test func listenURLCarriesTheTunedParameters() {
		let url = Deepgram.listenURL(language: "zh-CN").absoluteString
		#expect(url.hasPrefix("wss://api.deepgram.com/v1/listen?model=nova-3&encoding=linear16&sample_rate=16000&channels=1"))
		#expect(url.contains("endpointing=300"))
		#expect(url.hasSuffix("language=zh-CN"))
	}

	@Test func onlyFinalResultsCount() {
		let final = #"{"type":"Results","is_final":true,"channel":{"alternatives":[{"transcript":"hello there"}]}}"#
		let interim = #"{"type":"Results","is_final":false,"channel":{"alternatives":[{"transcript":"hello"}]}}"#
		let empty = #"{"type":"Results","is_final":true,"channel":{"alternatives":[{"transcript":""}]}}"#
		let meta = #"{"type":"Metadata"}"#
		#expect(Deepgram.finalTranscript(in: Data(final.utf8)) == "hello there")
		#expect(Deepgram.finalTranscript(in: Data(interim.utf8)) == nil)
		#expect(Deepgram.finalTranscript(in: Data(empty.utf8)) == nil)
		#expect(Deepgram.finalTranscript(in: Data(meta.utf8)) == nil)
	}
}
