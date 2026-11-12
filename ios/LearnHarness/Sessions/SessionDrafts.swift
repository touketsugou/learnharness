import LHAPI
import Observation

/// A question form's unsent state (the web's QuestionFormDraft). Indices are
/// the dock's display order.
struct QuestionFormDraft: Hashable {
	var selected: Set<Int> = []
	var otherSelected = false
	var other = ""
	var dontKnow = false
	var answerText = ""
	var thinking = ""
	var confidenceIndex: Int

	init(confidenceIndex: Int) {
		self.confidenceIndex = confidenceIndex
	}
}

/// One session's unsent input. Held by AppModel so it outlives the session
/// page (switching sessions or tabs); kept in memory only, never written to
/// storage (web parity).
@MainActor
@Observable
final class SessionDrafts {
	var composer = ""
	/// Question forms per question key.
	var questions: [String: QuestionFormDraft] = [:]
	/// Reading-thinking drafts per question key.
	var readingThinking: [String: String] = [:]
	/// Question keys whose "Check your understanding" reveal was opened.
	var revealedQuestions: Set<String> = []
	/// Practice answers per problem call id.
	var problems: [String: String] = [:]

	/// Keep only the drafts of the question and problem still open (the web's
	/// forgetResolvedDrafts).
	func forgetResolved(dock: NativeDock?) {
		var questionKey: String?
		var problemId: String?
		switch dock {
		case .question(let question): questionKey = question.key
		case .problem(let problem): problemId = problem.toolCallId
		default: break
		}
		// This runs on every stream frame: assign only on a change, so the
		// docks reading these don't redraw per frame.
		if questions.keys.contains(where: { $0 != questionKey }) { questions = questions.filter { $0.key == questionKey } }
		if readingThinking.keys.contains(where: { $0 != questionKey }) { readingThinking = readingThinking.filter { $0.key == questionKey } }
		if revealedQuestions.contains(where: { $0 != questionKey }) { revealedQuestions = revealedQuestions.filter { $0 == questionKey } }
		if problems.keys.contains(where: { $0 != problemId }) { problems = problems.filter { $0.key == problemId } }
	}

	/// Text that failed to send goes back in front of anything typed since,
	/// a blank line between.
	nonisolated static func restoring(_ unsent: String, into current: String) -> String {
		current.isEmpty ? unsent : unsent + "\n\n" + current
	}
}
