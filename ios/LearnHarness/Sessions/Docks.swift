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
	@State private var text = ""
	@FocusState private var focused: Bool

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			if nextReady && !model.isRunning && !model.submitting {
				Button { Task { await model.nextProblem() } } label: {
					Label("Next problem", systemImage: "arrow.right")
				}
				.buttonStyle(.bordered)
			}
			HStack(alignment: .bottom, spacing: 6) {
				AttachButton(text: $text)
					.disabled(model.isCompacting)
				TextField(placeholder, text: $text, axis: .vertical)
					.lineLimit(1...6)
					.focused($focused)
					.padding(.horizontal, 12)
					.padding(.vertical, 9)
					.background(RoundedRectangle(cornerRadius: 18).fill(Color(uiColor: .secondarySystemBackground)))
					.disabled(model.isCompacting)
				MicButton(text: $text)
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
			let message = text
			text = ""
			await model.sendText(message)
		}
	}
}

// MARK: - Question dock

struct QuestionDockView: View {
	let model: SessionModel
	let dock: NativeQuestionDock
	@Environment(AppModel.self) private var app

	@State private var selected: Set<Int> = []
	@State private var otherSelected = false
	@State private var other = ""
	@State private var dontKnow = false
	@State private var answerText = ""
	@State private var thinking = ""
	@State private var confidenceIndex: Int
	@State private var expanded = true

	init(model: SessionModel, dock: NativeQuestionDock) {
		self.model = model
		self.dock = dock
		_confidenceIndex = State(initialValue: dock.defaultConfidenceIndex)
	}

	private var revealed: Bool { !dock.needsReveal || model.revealedQuestions.contains(dock.key) }
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
		if !isSelect { return !answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
		return dontKnow || (otherSelected && !other.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || !selected.isEmpty
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			if revealed {
				ScrollView {
					form.padding(.horizontal, 14).padding(.top, 12)
				}
				.scrollBounceBehavior(.basedOnSize)
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
				model.revealedQuestions.insert(dock.key)
			} label: {
				Label("Check your understanding", systemImage: "play.fill").frame(maxWidth: .infinity)
			}
			.buttonStyle(.borderedProminent)
		}
		.padding(14)
	}

	private var readingThinking: Binding<String> {
		Binding(get: { model.readingThinking[dock.key] ?? "" }, set: { model.readingThinking[dock.key] = $0 })
	}

	@ViewBuilder private var form: some View {
		VStack(alignment: .leading, spacing: 12) {
			HStack {
				CardLabel(text: label)
				Spacer()
				Button { withAnimation { expanded.toggle() } } label: {
					Image(systemName: expanded ? "chevron.down" : "chevron.up")
				}
				.buttonStyle(.borderless)
				.accessibilityLabel(expanded ? "Collapse" : "Expand")
			}
			MarkdownView(dock.question).fontWeight(.medium)
			if let context = dock.context, !context.isEmpty {
				MarkdownView(context, textStyle: .callout).foregroundStyle(.secondary)
			}
			if isSelect {
				ForEach(Array(dock.options.enumerated()), id: \.offset) { index, option in
					OptionRow(option: option, selected: selected.contains(index), multi: dock.mode == .multiSelect) { toggle(index) }
						.disabled(dontKnow)
				}
				if dock.kind == "ask" {
					OptionRow(option: QuizOption(label: "Other…", value: "", description: nil), selected: otherSelected, multi: dock.mode == .multiSelect) {
						otherSelected.toggle()
						if otherSelected, dock.mode == .singleSelect { selected.removeAll() }
					}
					if otherSelected {
						TextField("Type your own answer…", text: $other, axis: .vertical).textFieldStyle(.roundedBorder)
					}
				}
				if isQuiz {
					Toggle(isOn: Binding(get: { dontKnow }, set: { dontKnow = $0; if $0 { selected.removeAll(); otherSelected = false } })) {
						Text("I don't know")
					}
					.toggleStyle(.button)
					.buttonStyle(.bordered)
				}
				if isQuiz {
					ConfidencePicker(stops: dock.confidenceStops, index: $confidenceIndex, disabled: dontKnow)
				}
				TextField("Your thinking (optional)…", text: $thinking, axis: .vertical)
					.lineLimit(2...6)
					.padding(10)
					.background(RoundedRectangle(cornerRadius: 12).fill(Color(uiColor: .secondarySystemBackground)))
			} else {
				TextField("Your answer…", text: $answerText, axis: .vertical)
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
			MicButton(text: isSelect ? $thinking : $answerText)
			Button(action: submit) { Text("Submit").frame(minWidth: 90) }
				.buttonStyle(.borderedProminent)
				.disabled(!canSubmit)
		}
		.padding(14)
	}

	private func toggle(_ index: Int) {
		if dock.mode == .multiSelect {
			if selected.contains(index) { selected.remove(index) } else { selected.insert(index) }
		} else {
			selected = selected.contains(index) ? [] : [index]
			otherSelected = false
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
		let trimmedThinking = thinking.trimmingCharacters(in: .whitespacesAndNewlines)
		let request = AnswerRequest(
			dontKnow: dontKnow,
			values: selected.sorted().map { dock.options[$0].value },
			other: otherSelected ? other : nil,
			text: isSelect ? nil : answerText,
			thinking: isSelect && !trimmedThinking.isEmpty ? trimmedThinking : nil,
			confidence: isQuiz ? dock.confidenceStops[safe: confidenceIndex] : nil
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
	@State private var thinking = ""
	@State private var showStatement = true

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
			TextField("Your thinking or answer…", text: $thinking, axis: .vertical)
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
				MicButton(text: $thinking)
				Button("Submit") {
					Task {
						await app.dictation?.finish()
						let text = thinking
						guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
						thinking = ""
						await model.submitThinking(problemCallId: problem.toolCallId, text: text)
					}
				}
				.buttonStyle(.borderedProminent)
				.disabled(thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.canAct)
			}
		}
		.padding(14)
	}
}

extension Array {
	subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
