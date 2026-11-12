import LHAPI
import LHRender
import SwiftUI

/// What sits at the bottom of a session: the pending question, the active
/// practice problem, or the composer (web parity: a dock replaces the composer).
struct SessionDock: View {
	let model: SessionModel

	var body: some View {
		VStack(spacing: 0) {
			Divider()
			if !model.offline { DictationStatusRow() }
			Group {
				if model.offline {
					Label("Offline — read-only copy", systemImage: "wifi.slash")
						.font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(14)
				} else {
					switch model.state?.dock {
					case .question(let dock):
						QuestionDockView(model: model, dock: dock).id(dock.key)
					case .problem(let problem):
						PracticeDockView(model: model, problem: problem).id(problem.toolCallId)
					default:
						ComposerView(model: model, nextReady: model.state?.dock == .betweenProblems)
					}
				}
			}
			.background(.bar)
		}
	}
}

// MARK: - Composer

struct ComposerView: View {
	let model: SessionModel
	let nextReady: Bool
	@Environment(AppModel.self) private var app
	@FocusState private var focused: Bool

	var body: some View {
		@Bindable var drafts = model.drafts
		let text = drafts.composer
		VStack(alignment: .leading, spacing: 8) {
			if nextReady && !model.isRunning && !model.submitting {
				Button { Task { await model.nextProblem() } } label: {
					Label("Next problem", systemImage: "arrow.right")
				}
				.buttonStyle(.bordered)
			}
			HStack(alignment: .bottom, spacing: 6) {
				AttachButton(text: $drafts.composer)
					.disabled(model.isCompacting)
				TextField(placeholder, text: $drafts.composer, axis: .vertical)
					.lineLimit(1...6)
					.focused($focused)
					.padding(.horizontal, 12)
					.padding(.vertical, 9)
					.background(RoundedRectangle(cornerRadius: 18).fill(Color(uiColor: .secondarySystemBackground)))
					.disabled(model.isCompacting)
				MicButton(text: $drafts.composer)
				if model.isRunning && text.trimmingCharacters(in: .whitespaces).isEmpty {
					Button { Task { await model.stopTurn() } } label: {
						Image(systemName: "stop.circle.fill").font(.title)
					}
					.accessibilityLabel("Stop")
					.tint(.red)
				} else {
					Button(action: send) {
						Image(systemName: "arrow.up.circle.fill").font(.title)
					}
					.accessibilityLabel(model.isRunning ? "Send to the running turn" : "Send")
					.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.submitting || model.isCompacting)
				}
			}
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 10)
	}

	private var placeholder: String {
		if model.isCompacting { return "Compacting context…" }
		if model.isRunning { return "Add to the running turn…" }
		return model.view?.messages.isEmpty ?? true ? "What do you want to learn?" : "Message"
	}

	/// Finish any dictation first, so the whole transcript goes out.
	private func send() {
		Task {
			await app.dictation?.finish()
			let message = model.drafts.composer
			model.drafts.composer = ""
			await model.sendText(message)
		}
	}
}

// MARK: - Question dock

struct QuestionDockView: View {
	let model: SessionModel
	let dock: NativeQuestionDock
	@Environment(AppModel.self) private var app

	@State private var expanded = true

	/// This question's form, kept in the session's drafts.
	private var draft: QuestionFormDraft {
		get { model.drafts.questions[dock.key] ?? QuestionFormDraft(confidenceIndex: dock.defaultConfidenceIndex) }
		nonmutating set { model.drafts.questions[dock.key] = newValue }
	}

	private var draftBinding: Binding<QuestionFormDraft> {
		Binding(get: { draft }, set: { draft = $0 })
	}

	private var revealed: Bool { !dock.needsReveal || model.drafts.revealedQuestions.contains(dock.key) }
	private var isSelect: Bool { dock.mode != .text }
	private var isQuiz: Bool { dock.kind == "quiz" }

	private var label: String {
		let base: String = switch dock.tool {
		case "probe": "Probe"
		case "recall": "Recall"
		default: isQuiz ? (dock.questionType == "predict" ? "Prediction" : "Check") : dock.kind == "explain" ? "Explain" : "Question"
		}
		return dock.mode == .multiSelect ? "\(base) · select all that apply" : base
	}

	private var canSubmit: Bool {
		if model.submitting || model.isCompacting || model.isRunning { return false }
		let draft = draft
		if !isSelect { return !draft.answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
		return draft.dontKnow || (draft.otherSelected && !draft.other.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || !draft.selected.isEmpty
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			if revealed {
				// The label row stays put; the question beneath it scrolls.
				VStack(alignment: .leading, spacing: 0) {
					header.padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 12)
					ScrollView {
						form.padding(.horizontal, 14)
					}
					.scrollBounceBehavior(.basedOnSize)
				}
				.frame(maxHeight: expanded ? 460 : 120)
				actions
			} else {
				reveal
			}
		}
	}

	// The teach-phase check waits behind the reveal; thinking while reading
	// is captured here and rides the answer (or the skip).
	private var reveal: some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack(alignment: .bottom, spacing: 6) {
				TextField("Your thinking while reading (optional)…", text: readingThinking, axis: .vertical)
					.lineLimit(1...4)
					.padding(10)
					.background(RoundedRectangle(cornerRadius: 12).fill(Color(uiColor: .secondarySystemBackground)))
				MicButton(text: readingThinking)
			}
			Button {
				model.drafts.revealedQuestions.insert(dock.key)
			} label: {
				Label("Check your understanding", systemImage: "play.fill").frame(maxWidth: .infinity)
			}
			.buttonStyle(.borderedProminent)
		}
		.padding(14)
	}

	private var readingThinking: Binding<String> {
		Binding(get: { model.drafts.readingThinking[dock.key] ?? "" }, set: { model.drafts.readingThinking[dock.key] = $0 })
	}

	private var header: some View {
		HStack {
			CardLabel(text: label)
			Spacer()
			Button { withAnimation { expanded.toggle() } } label: {
				Image(systemName: expanded ? "chevron.down" : "chevron.up")
			}
			.buttonStyle(.borderless)
			.accessibilityLabel(expanded ? "Collapse" : "Expand")
		}
	}

	@ViewBuilder private var form: some View {
		let draft = draft
		VStack(alignment: .leading, spacing: 12) {
			MarkdownView(dock.question).fontWeight(.medium)
			if let context = dock.context, !context.isEmpty {
				MarkdownView(context, textStyle: .callout).foregroundStyle(.secondary)
			}
			if isSelect {
				ForEach(Array(dock.options.enumerated()), id: \.offset) { index, option in
					OptionRow(option: option, selected: draft.selected.contains(index), multi: dock.mode == .multiSelect) { toggle(index) }
						.disabled(draft.dontKnow)
				}
				if dock.kind == "ask" {
					OptionRow(option: QuizOption(label: "Other…", value: "", description: nil), selected: draft.otherSelected, multi: dock.mode == .multiSelect) {
						self.draft.otherSelected.toggle()
						if self.draft.otherSelected, dock.mode == .singleSelect { self.draft.selected.removeAll() }
					}
					if draft.otherSelected {
						TextField("Type your own answer…", text: draftBinding.other, axis: .vertical).textFieldStyle(.roundedBorder)
					}
				}
				if isQuiz {
					Toggle(isOn: Binding(get: { self.draft.dontKnow }, set: { on in
						self.draft.dontKnow = on
						if on { self.draft.selected.removeAll(); self.draft.otherSelected = false }
					})) {
						Text("I don't know")
					}
					.toggleStyle(.button)
					.buttonStyle(.bordered)
				}
				if isQuiz {
					ConfidencePicker(stops: dock.confidenceStops, index: draftBinding.confidenceIndex, disabled: draft.dontKnow)
				}
				TextField("Your thinking (optional)…", text: draftBinding.thinking, axis: .vertical)
					.lineLimit(2...6)
					.padding(10)
					.background(RoundedRectangle(cornerRadius: 12).fill(Color(uiColor: .secondarySystemBackground)))
			} else {
				TextField("Your answer…", text: draftBinding.answerText, axis: .vertical)
					.lineLimit(3...10)
					.padding(10)
					.background(RoundedRectangle(cornerRadius: 12).fill(Color(uiColor: .secondarySystemBackground)))
			}
		}
	}

	private var actions: some View {
		HStack {
			Button("Skip", role: .destructive) { Task { await model.dismissQuestion(dock) } }
				.buttonStyle(.bordered)
			Spacer()
			// The dictation target: the answer (text mode) or "Your thinking".
			MicButton(text: isSelect ? draftBinding.thinking : draftBinding.answerText)
			Button(action: submit) { Text("Submit").frame(minWidth: 90) }
				.buttonStyle(.borderedProminent)
				.disabled(!canSubmit)
		}
		.padding(14)
	}

	private func toggle(_ index: Int) {
		if dock.mode == .multiSelect {
			if draft.selected.contains(index) { draft.selected.remove(index) } else { draft.selected.insert(index) }
		} else {
			draft.selected = draft.selected.contains(index) ? [] : [index]
			draft.otherSelected = false
		}
	}

	private func submit() {
		Task {
			await app.dictation?.finish()
			submitNow()
		}
	}

	private func submitNow() {
		guard canSubmit else { return }
		let draft = draft
		let trimmedThinking = draft.thinking.trimmingCharacters(in: .whitespacesAndNewlines)
		let request = AnswerRequest(
			dontKnow: draft.dontKnow,
			values: draft.selected.sorted().map { dock.options[$0].value },
			other: draft.otherSelected ? draft.other : nil,
			text: isSelect ? nil : draft.answerText,
			thinking: isSelect && !trimmedThinking.isEmpty ? trimmedThinking : nil,
			confidence: isQuiz ? dock.confidenceStops[safe: draft.confidenceIndex] : nil
		)
		Task { await model.answer(dock, request: request) }
	}
}

private struct OptionRow: View {
	let option: QuizOption
	let selected: Bool
	let multi: Bool
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			HStack(alignment: .firstTextBaseline, spacing: 10) {
				Image(systemName: multi ? (selected ? "checkmark.square.fill" : "square") : (selected ? "largecircle.fill.circle" : "circle"))
					.foregroundStyle(selected ? Color.accentColor : .secondary)
				VStack(alignment: .leading, spacing: 2) {
					MarkdownView(option.label)
					if let description = option.description, !description.isEmpty {
						MarkdownView(description, textStyle: .footnote).foregroundStyle(.secondary)
					}
				}
			}
			.padding(10)
			.frame(maxWidth: .infinity, alignment: .leading)
			.background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.accentColor.opacity(0.1) : Color(uiColor: .secondarySystemBackground)))
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.accessibilityAddTraits(selected ? .isSelected : [])
	}
}

/// The stated probability that the selection is correct, snapped to the stops.
private struct ConfidencePicker: View {
	let stops: [Int]
	@Binding var index: Int
	let disabled: Bool

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack {
				CardLabel(text: "Confidence")
				Spacer()
				Text(disabled ? "—" : "\(stops[safe: index] ?? 50)%").font(.callout.monospacedDigit().weight(.semibold))
			}
			Picker("Confidence", selection: $index) {
				ForEach(Array(stops.enumerated()), id: \.offset) { offset, stop in Text("\(stop)").tag(offset) }
			}
			.pickerStyle(.segmented)
			.disabled(disabled)
		}
	}
}

// MARK: - Practice dock

struct PracticeDockView: View {
	let model: SessionModel
	let problem: NativeProblemDock
	@Environment(AppModel.self) private var app
	@State private var showStatement = true

	/// The answer being written, kept in the session's drafts.
	private var thinking: Binding<String> {
		Binding(get: { model.drafts.problems[problem.toolCallId] ?? "" }, set: { model.drafts.problems[problem.toolCallId] = $0 })
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			DisclosureGroup(isExpanded: $showStatement) {
				ScrollView {
					MarkdownView(problem.statement ?? "").frame(maxWidth: .infinity, alignment: .leading)
				}
				.frame(maxHeight: 220)
			} label: {
				CardLabel(text: "Problem\(problem.mode.map { " · \($0)" } ?? "")", systemImage: "puzzlepiece")
			}
			.tint(.secondary)
			TextField("Your thinking or answer…", text: thinking, axis: .vertical)
				.lineLimit(2...8)
				.padding(10)
				.background(RoundedRectangle(cornerRadius: 12).fill(Color(uiColor: .secondarySystemBackground)))
			HStack {
				Button("Discard", role: .destructive) { Task { await model.discardProblem(problem.toolCallId) } }
					.buttonStyle(.bordered)
				Spacer()
				if model.isRunning {
					Button { Task { await model.stopTurn() } } label: { Image(systemName: "stop.circle.fill") }
						.tint(.red)
				}
				MicButton(text: thinking)
				Button("Submit") {
					Task {
						await app.dictation?.finish()
						let text = thinking.wrappedValue
						guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
						thinking.wrappedValue = ""
						await model.submitThinking(problemCallId: problem.toolCallId, text: text)
					}
				}
				.buttonStyle(.borderedProminent)
				.disabled(thinking.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.canAct)
			}
		}
		.padding(14)
	}
}

extension Array {
	subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
