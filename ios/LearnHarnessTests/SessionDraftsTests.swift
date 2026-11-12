import Foundation
import LHAPI
import Testing
@testable import LearnHarness

@MainActor
@Suite("Session drafts")
struct SessionDraftsTests {
	func dock(_ json: String) throws -> NativeDock {
		try JSONDecoder().decode(NativeDock.self, from: Data(json.utf8))
	}

	func question(_ key: String) throws -> NativeDock {
		try dock("""
		{"type":"question","toolCallId":"\(key)","key":"\(key)","tool":"quiz","kind":"quiz","question":"Q","mode":"single-select",
		"options":[],"needsReveal":true,"confidenceStops":[50,70,90],"defaultConfidenceIndex":1}
		""")
	}

	func filled() -> SessionDrafts {
		let drafts = SessionDrafts()
		drafts.composer = "unsent message"
		for key in ["q1", "q2"] {
			drafts.questions[key] = QuestionFormDraft(confidenceIndex: 1)
			drafts.readingThinking[key] = "reading \(key)"
			drafts.revealedQuestions.insert(key)
		}
		drafts.problems["p1"] = "work 1"
		drafts.problems["p2"] = "work 2"
		return drafts
	}

	@Test func keepsOnlyThePendingQuestion() throws {
		let drafts = filled()
		drafts.forgetResolved(dock: try question("q2"))
		#expect(Set(drafts.questions.keys) == ["q2"])
		#expect(drafts.readingThinking == ["q2": "reading q2"])
		#expect(drafts.revealedQuestions == ["q2"])
		#expect(drafts.problems.isEmpty)
		#expect(drafts.composer == "unsent message")
	}

	@Test func keepsOnlyTheOpenProblem() throws {
		let drafts = filled()
		drafts.forgetResolved(dock: try dock(#"{"type":"problem","toolCallId":"p1"}"#))
		#expect(drafts.problems == ["p1": "work 1"])
		#expect(drafts.questions.isEmpty)
		#expect(drafts.readingThinking.isEmpty)
		#expect(drafts.revealedQuestions.isEmpty)
	}

	@Test func noDockForgetsEveryQuestionAndProblem() {
		let drafts = filled()
		drafts.forgetResolved(dock: nil)
		#expect(drafts.questions.isEmpty)
		#expect(drafts.problems.isEmpty)
		#expect(drafts.composer == "unsent message")
	}

	@Test func restoredTextGoesInFrontOfNewTyping() {
		#expect(SessionDrafts.restoring("sent", into: "") == "sent")
		#expect(SessionDrafts.restoring("sent", into: "typed since") == "sent\n\ntyped since")
	}

	@Test func appModelKeepsDraftsPerSessionUntilSignOut() async {
		let defaults = UserDefaults(suiteName: "lh-tests-\(UUID().uuidString)")!
		defaults.set("https://learn.example.com", forKey: "serverURL")
		let tokens = MemoryTokenStore()
		tokens.token = "t"
		let model = AppModel(tokens: tokens, defaults: defaults)
		model.drafts(for: "a").composer = "hello"
		#expect(model.drafts(for: "a").composer == "hello")
		#expect(model.drafts(for: "b").composer == "")
		model.forgetDrafts(for: "a")
		#expect(model.drafts(for: "a").composer == "")
		model.drafts(for: "a").composer = "again"
		await model.signOut()
		#expect(model.drafts(for: "a").composer == "")
	}
}
