import LHAPI
import LHRender
import SwiftUI

/// What sits at the bottom of a session: the pending question, the active
/// practice problem, or the composer (web parity: a dock replaces the composer).
struct SessionDock: View {
	let model: SessionModel
	/// The transcript and dock's height (nil: not measured yet). Each dock
	/// takes its content's height up to its share of it; its scrolling part
	/// gives way.
	var visibleHeight: CGFloat?
	/// The question dock's ceiling, as a share of the height: the learner drags
	/// it (QuestionDockSize), and it holds for later questions.
	@AppStorage(QuestionDockSize.key) private var questionShare = QuestionDockSize.defaultShare

	/// A question gets the learner's share (60% at first): its options scroll
	/// between a header and pinned answer controls. A problem or plugin
	/// question gets half.
	private func limit(_ share: CGFloat) -> CGFloat? { visibleHeight.map { $0 * share } }

	var body: some View {
		VStack(spacing: 0) {
			Rectangle().fill(LHColor.hairline).frame(height: 1)
			if !model.offline { DictationStatusRow() }
			Group {
				if model.offline {
					Label("Offline — read-only copy", systemImage: "wifi.slash")
						.font(LHFont.prose(.callout)).foregroundStyle(LHColor.muted).frame(maxWidth: .infinity).padding(14)
				} else {
					switch model.state?.dock {
					case .question(let dock):
						QuestionDockView(model: model, dock: dock, visibleHeight: visibleHeight, share: $questionShare).id(dock.key)
							.modifier(DockHeight(maxHeight: limit(questionShare)))
					case .problem(let problem):
						PracticeDockView(model: model, problem: problem).id(problem.toolCallId)
							.modifier(DockHeight(maxHeight: limit(0.5)))
					case .pluginQuestion(let dock):
						PluginQuestionDockView(model: model, dock: dock).id(dock.toolCallId)
							.modifier(DockHeight(maxHeight: limit(0.5)))
					default:
						ComposerView(model: model, nextReady: model.state?.dock == .betweenProblems)
					}
				}
			}
			.background(LHColor.bg)
		}
	}
}

/// The safe-area inset offers a dock the whole height and a scroll view takes
/// all it is offered, so a short question would sit above empty space. Sized
/// at its ideal height instead, a dock fits its content, and a limit below
/// that squeezes the dock's scroll view.
private struct DockHeight: ViewModifier {
	let maxHeight: CGFloat?

	func body(content: Content) -> some View {
		content
			.frame(maxHeight: maxHeight ?? .infinity)
			.fixedSize(horizontal: false, vertical: true)
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
					HStack(spacing: 8) {
						Text("Next problem")
						Image(systemName: "arrow.right")
					}
				}
				.buttonStyle(PrimaryButtonStyle())
			}
			HStack(alignment: .bottom, spacing: 8) {
				AttachButton(text: $drafts.composer)
					.modifier(CircleChrome())
					.disabled(model.isCompacting)
				ComposerField(placeholder: placeholder, text: $drafts.composer, lines: 1...6, focused: $focused)
					.disabled(model.isCompacting)
				if model.isRunning && text.trimmingCharacters(in: .whitespaces).isEmpty {
					StopButton { Task { await model.stopTurn() } }
				} else {
					SendButton(label: model.isRunning ? "Send to the running turn" : "Send",
							   enabled: !(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.submitting || model.isCompacting),
							   action: send)
				}
			}
		}
		.padding(.horizontal, 12)
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

// MARK: - Dock parts

/// The message field: a raised capsule with the mic inside.
struct ComposerField: View {
	let placeholder: String
	@Binding var text: String
	var lines: ClosedRange<Int> = 1...6
	var focused: FocusState<Bool>.Binding?

	var body: some View {
		HStack(alignment: .bottom, spacing: 4) {
			field
				.font(LHFont.prose(.body))
				.lineLimit(lines)
				.padding(.vertical, 11)
				.padding(.leading, 16)
			MicButton(text: $text)
				.foregroundStyle(LHColor.muted)
				.padding(.trailing, 6)
				.padding(.bottom, 6)
		}
		.frame(minHeight: 44)
		.background(RoundedRectangle(cornerRadius: 22).fill(LHColor.raised))
		.overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(LHColor.hairline))
	}

	@ViewBuilder private var field: some View {
		if let focused {
			TextField(placeholder, text: $text, axis: .vertical).focused(focused)
		} else {
			TextField(placeholder, text: $text, axis: .vertical)
		}
	}
}

/// A multi-line answer box: raised, rounded 12, the mic in its corner.
struct AnswerField: View {
	let placeholder: String
	@Binding var text: String
	var lines: ClosedRange<Int> = 2...6

	var body: some View {
		HStack(alignment: .bottom, spacing: 4) {
			TextField(placeholder, text: $text, axis: .vertical)
				.font(LHFont.prose(.body))
				.lineLimit(lines)
				.padding(.vertical, 10)
				.padding(.leading, 12)
			MicButton(text: $text)
				.foregroundStyle(LHColor.muted)
				.padding(.trailing, 4)
				.padding(.bottom, 4)
		}
		.background(RoundedRectangle(cornerRadius: 12).fill(LHColor.raised))
		.overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(LHColor.hairline))
	}
}

/// A 44 pt raised circle around an icon button.
struct CircleChrome: ViewModifier {
	func body(content: Content) -> some View {
		content
			.foregroundStyle(LHColor.ink)
			.frame(width: 44, height: 44)
			.background(Circle().fill(LHColor.raised))
			.overlay(Circle().strokeBorder(LHColor.hairline))
	}
}

struct SendButton: View {
	let label: String
	let enabled: Bool
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			Image(systemName: "arrow.up")
				.font(.system(size: 18, weight: .bold))
				.foregroundStyle(enabled ? LHColor.bg : LHColor.muted)
				.frame(width: 44, height: 44)
				.background(Circle().fill(enabled ? LHColor.ink : LHColor.hairline))
		}
		.buttonStyle(.plain)
		.disabled(!enabled)
		.accessibilityLabel(label)
	}
}

struct StopButton: View {
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			Image(systemName: "stop.fill")
				.font(.system(size: 15, weight: .bold))
				.foregroundStyle(.white)
				.frame(width: 44, height: 44)
				.background(Circle().fill(LHColor.error))
		}
		.buttonStyle(.plain)
		.accessibilityLabel("Stop")
	}
}

/// The dock's main action: a full-width ink capsule; grey while disabled.
struct PrimaryButtonStyle: ButtonStyle {
	@Environment(\.isEnabled) private var isEnabled

	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.font(LHFont.prose(.body).weight(.semibold))
			.foregroundStyle(isEnabled ? LHColor.bg : LHColor.muted)
			.frame(maxWidth: .infinity, minHeight: 44)
			.background(Capsule().fill(isEnabled ? LHColor.ink : LHColor.hairline))
			.opacity(configuration.isPressed ? 0.8 : 1)
			.contentShape(Capsule())
	}
}

/// A quiet text action in a dock's header (Skip, Discard).
struct QuietButton: View {
	let title: String
	let action: () -> Void

	var body: some View {
		Button(title, action: action)
			.font(LHFont.prose(.subheadline).weight(.medium))
			.foregroundStyle(LHColor.muted)
			.buttonStyle(.plain)
			.frame(minWidth: 44, minHeight: 44)
			.contentShape(Rectangle())
	}
}

/// The collapse / expand chevron in a dock's header.
struct DockChevron: View {
	@Binding var expanded: Bool

	var body: some View {
		Button { withAnimation(.snappy) { expanded.toggle() } } label: {
			Image(systemName: expanded ? "chevron.down" : "chevron.up")
				.font(.system(size: 14, weight: .semibold))
				.foregroundStyle(LHColor.muted)
				.frame(width: 44, height: 44)
				.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.accessibilityLabel(expanded ? "Collapse" : "Expand")
	}
}

// MARK: - Question dock

/// The question dock's height ceiling, which the learner drags: a share of
/// the height above the keyboard and tab bar, kept across questions.
enum QuestionDockSize {
	static let key = "questionDockShare"
	static let defaultShare = 0.6
	static let maxShare = 0.9
	/// The question's least visible height (about two lines).
	static let peek: CGFloat = 56

	/// The share after moving the dock's top edge `drag` points down (negative:
	/// up) from a dock `base` tall, kept between `minHeight` and 90%; `current`
	/// while the height isn't measured.
	static func share(_ current: Double, base: CGFloat, drag: CGFloat, minHeight: CGFloat, visibleHeight: CGFloat?) -> Double {
		guard let visibleHeight, visibleHeight > 0 else { return current }
		let maxHeight = visibleHeight * maxShare
		let height = min(max(base - drag, min(minHeight, maxHeight)), maxHeight)
		return Double(height / visibleHeight)
	}
}

struct QuestionDockView: View {
	let model: SessionModel
	let dock: NativeQuestionDock
	var visibleHeight: CGFloat?
	/// The ceiling's share (SessionDock applies it); the handle sets it.
	@Binding var share: Double
	@Environment(AppModel.self) private var app

	/// The form's height: the scroll view grows no taller.
	@State private var formHeight: CGFloat?
	/// The dock's and its scroll view's drawn heights, which a drag starts from.
	@State private var dockHeight: CGFloat = 0
	@State private var scrollHeight: CGFloat = 0
	/// The dock's height when the current drag began.
	@State private var dragBase: CGFloat?
	@State private var resized = 0

	/// This question's form, kept in the session's drafts.
	private var draft: QuestionFormDraft {
		get { model.drafts.questions[dock.key] ?? QuestionFormDraft(confidenceIndex: dock.defaultConfidenceIndex) }
		nonmutating set { model.drafts.questions[dock.key] = newValue }
	}

	private var draftBinding: Binding<QuestionFormDraft> {
		Binding(get: { draft }, set: { draft = $0 })
	}

	private var revealed: Bool { !dock.needsReveal || model.drafts.revealedQuestions.contains(dock.key) }

	/// What picking changes in the form, not its text: each change is one
	/// selection tick (a single-select switch clears one option and picks
	/// another at once).
	private struct Picks: Equatable {
		var selected: Set<Int>
		var otherSelected: Bool
		var dontKnow: Bool
		var confidenceIndex: Int
	}

	private var picks: Picks {
		let draft = draft
		return Picks(selected: draft.selected, otherSelected: draft.otherSelected, dontKnow: draft.dontKnow, confidenceIndex: draft.confidenceIndex)
	}
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
				// The header and the answer controls stay put; the question and
				// its options scroll between them, giving way first. The handle
				// and header drag the dock's height.
				VStack(spacing: 0) {
					handle
					header.padding(.leading, 14).padding(.trailing, 4)
				}
				.contentShape(Rectangle())
				.gesture(resize)
				ScrollView {
					form.padding(.horizontal, 14).padding(.bottom, 10)
						.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { formHeight = $0 }
				}
				.scrollBounceBehavior(.basedOnSize)
				.frame(maxHeight: formHeight ?? 460)
				.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { scrollHeight = $0 }
				pinned
					.padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 10)
					.fixedSize(horizontal: false, vertical: true)
			} else {
				reveal
			}
		}
		.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { dockHeight = $0 }
		.sensoryFeedback(.selection, trigger: picks)
		.sensoryFeedback(.impact(weight: .light), trigger: resized)
	}

	/// The least height: the header, a peek of the question, the pinned controls.
	private var minHeight: CGFloat {
		dockHeight - scrollHeight + min(QuestionDockSize.peek, formHeight ?? QuestionDockSize.peek)
	}

	/// Moving the top edge resizes from the height as drawn (a short question
	/// sits below its ceiling). Global, as the dock moves under the finger.
	private var resize: some Gesture {
		DragGesture(minimumDistance: 4, coordinateSpace: .global)
			.onChanged { value in
				let base = dragBase ?? dockHeight
				dragBase = base
				share = QuestionDockSize.share(share, base: base, drag: value.translation.height, minHeight: minHeight, visibleHeight: visibleHeight)
			}
			.onEnded { _ in
				dragBase = nil
				resized += 1
			}
	}

	private var handle: some View {
		Capsule()
			.fill(LHColor.edge)
			.frame(width: 36, height: 5)
			.frame(maxWidth: .infinity)
			.frame(height: 20)
			.accessibilityElement()
			.accessibilityLabel("Question height")
			.accessibilityValue("\(Int((share * 100).rounded()))%")
			.accessibilityAdjustableAction { direction in
				let step = (visibleHeight ?? 0) * 0.1
				switch direction {
				case .increment:
					share = QuestionDockSize.share(share, base: CGFloat(share) * (visibleHeight ?? 0), drag: -step, minHeight: minHeight, visibleHeight: visibleHeight)
				case .decrement:
					share = QuestionDockSize.share(share, base: dockHeight, drag: step, minHeight: minHeight, visibleHeight: visibleHeight)
				@unknown default: break
				}
			}
	}

	// The teach-phase check waits behind the reveal; thinking while reading
	// is captured here and rides the answer (or the skip).
	private var reveal: some View {
		VStack(alignment: .leading, spacing: 10) {
			AnswerField(placeholder: "Your thinking while reading (optional)…", text: readingThinking, lines: 1...4)
			Button {
				model.drafts.revealedQuestions.insert(dock.key)
			} label: {
				Label("Check your understanding", systemImage: "play.fill")
			}
			.buttonStyle(PrimaryButtonStyle())
		}
		.padding(14)
	}

	private var readingThinking: Binding<String> {
		Binding(get: { model.drafts.readingThinking[dock.key] ?? "" }, set: { model.drafts.readingThinking[dock.key] = $0 })
	}

	private var header: some View {
		HStack(spacing: 0) {
			CardLabel(text: label)
			Spacer()
			QuietButton(title: "Skip") { Task { await model.dismissQuestion(dock) } }
		}
	}

	@ViewBuilder private var form: some View {
		let draft = draft
		VStack(alignment: .leading, spacing: 10) {
			MarkdownView(dock.question).fontWeight(.medium)
			if let context = dock.context, !context.isEmpty {
				MarkdownView(context, textStyle: .callout).foregroundStyle(LHColor.muted)
			}
			if isSelect {
				ForEach(Array(dock.options.enumerated()), id: \.offset) { index, option in
					OptionRow(option: option, selected: draft.selected.contains(index), multi: dock.mode == .multiSelect) { toggle(index) }
						.disabled(draft.dontKnow)
						.opacity(draft.dontKnow ? 0.5 : 1)
				}
				if dock.kind == "ask" {
					OptionRow(option: QuizOption(label: "Other…", value: "", description: nil), selected: draft.otherSelected, multi: dock.mode == .multiSelect) {
						self.draft.otherSelected.toggle()
						if self.draft.otherSelected, dock.mode == .singleSelect { self.draft.selected.removeAll() }
					}
					if draft.otherSelected {
						AnswerField(placeholder: "Type your own answer…", text: draftBinding.other, lines: 1...4)
					}
				}
				if isQuiz {
					DontKnowRow(selected: draft.dontKnow) {
						let on = !self.draft.dontKnow
						self.draft.dontKnow = on
						if on { self.draft.selected.removeAll(); self.draft.otherSelected = false }
					}
				}
			}
		}
	}

	/// Below the scroll: confidence (quiz), the thinking or answer box, Submit.
	@ViewBuilder private var pinned: some View {
		let draft = draft
		VStack(alignment: .leading, spacing: 8) {
			if isSelect {
				if isQuiz {
					ConfidenceRail(stops: dock.confidenceStops, index: draftBinding.confidenceIndex, disabled: draft.dontKnow)
				}
				AnswerField(placeholder: "Your thinking (optional)…", text: draftBinding.thinking, lines: 1...4)
			} else {
				AnswerField(placeholder: "Your answer…", text: draftBinding.answerText, lines: 3...10)
			}
			Button("Submit", action: submit)
				.buttonStyle(PrimaryButtonStyle())
				.disabled(!canSubmit)
		}
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
					.foregroundStyle(selected ? LHColor.ink : LHColor.muted)
				VStack(alignment: .leading, spacing: 2) {
					MarkdownView(option.label)
					if let description = option.description, !description.isEmpty {
						MarkdownView(description, textStyle: .footnote).foregroundStyle(LHColor.muted)
					}
				}
			}
			.padding(.horizontal, 12)
			.padding(.vertical, 11)
			.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
			.background(RoundedRectangle(cornerRadius: 12).fill(LHColor.raised))
			.overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? LHColor.ink : LHColor.hairline, lineWidth: selected ? 1.5 : 1))
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.accessibilityAddTraits(selected ? .isSelected : [])
	}
}

/// "I don't know": a dashed row under the options (quiz only).
private struct DontKnowRow: View {
	let selected: Bool
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			HStack(spacing: 10) {
				Image(systemName: selected ? "questionmark.circle.fill" : "questionmark.circle")
				Text("I don't know").font(LHFont.prose(.body))
			}
			.foregroundStyle(selected ? LHColor.ink : LHColor.muted)
			.padding(.horizontal, 12)
			.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
			.overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? LHColor.ink : LHColor.edge, style: StrokeStyle(lineWidth: selected ? 1.5 : 1, dash: [4, 3])))
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.accessibilityAddTraits(selected ? .isSelected : [])
	}
}

/// The stated probability that the selection is correct: the desktop's rail
/// (components/confidence-rail.tsx), snapped to the stops, coloured by value.
struct ConfidenceRail: View {
	let stops: [Int]
	@Binding var index: Int
	let disabled: Bool

	private static let thumb: CGFloat = 22

	private var value: Int { stops[safe: index] ?? 50 }
	private var color: Color { disabled ? LHColor.edge : ConfidenceRamp.color(for: value) }

	var body: some View {
		// One row: label, rail, value. The rail keeps a 44 pt touch height.
		HStack(spacing: 12) {
			CardLabel(text: "Confidence").fixedSize()
			GeometryReader { geometry in
				let width = geometry.size.width
				let travel = width - Self.thumb
				let x = { (stop: Int) in Self.thumb / 2 + travel * CGFloat(stop) / 100 }
				ZStack(alignment: .leading) {
					Capsule().fill(LHColor.raised)
						.overlay(Capsule().strokeBorder(LHColor.hairline))
						.frame(height: 8)
					Capsule().fill(color)
						.frame(width: max(8, x(value)), height: 8)
					ForEach([30, 50, 70, 90], id: \.self) { tick in
						Rectangle().fill(LHColor.ink.opacity(0.35))
							.frame(width: 1.5, height: 8)
							.offset(x: x(tick) - 0.75)
					}
					Circle().fill(color)
						.overlay(Circle().strokeBorder(LHColor.bg, lineWidth: 2))
						.frame(width: Self.thumb, height: Self.thumb)
						.offset(x: x(value) - Self.thumb / 2)
				}
				.frame(height: 44)
				.contentShape(Rectangle())
				.gesture(DragGesture(minimumDistance: 0).onChanged { drag in
					guard !disabled, travel > 0 else { return }
					let picked = Double(drag.location.x - Self.thumb / 2) / Double(travel) * 100
					if let nearest = stops.indices.min(by: { abs(Double(stops[$0]) - picked) < abs(Double(stops[$1]) - picked) }), nearest != index {
						index = nearest
					}
				})
			}
			.frame(height: 44)
			Text(disabled ? "—" : "\(value)%")
				.font(LHFont.mono(.callout).weight(.semibold))
				.monospacedDigit()
				.foregroundStyle(disabled ? LHColor.muted : color)
				.fixedSize()
				.frame(minWidth: 44, alignment: .trailing)
		}
		.opacity(disabled ? 0.6 : 1)
		.accessibilityElement(children: .ignore)
		.accessibilityLabel("Confidence")
		.accessibilityValue(disabled ? "Not applicable" : "\(value) percent")
		.accessibilityAdjustableAction { direction in
			guard !disabled else { return }
			switch direction {
			case .increment: index = min(index + 1, stops.count - 1)
			case .decrement: index = max(index - 1, 0)
			@unknown default: break
			}
		}
	}
}

// MARK: - Practice dock

struct PracticeDockView: View {
	let model: SessionModel
	let problem: NativeProblemDock
	@Environment(AppModel.self) private var app
	/// Collapsed by default: the problem is in the transcript above.
	@State private var showStatement = false
	/// The statement's height: its scroll view grows no taller.
	@State private var statementHeight: CGFloat?

	/// The answer being written, kept in the session's drafts.
	private var thinking: Binding<String> {
		Binding(get: { model.drafts.problems[problem.toolCallId] ?? "" }, set: { model.drafts.problems[problem.toolCallId] = $0 })
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			header
			statement
			if let plugin = problem.plugin {
				pluginControls(plugin)
			} else {
				builtinControls
			}
		}
		.padding(.leading, 14).padding(.trailing, 14).padding(.top, 2).padding(.bottom, 12)
	}

	private var header: some View {
		HStack(spacing: 0) {
			let kind = problem.plugin.map { " · \($0.label)" } ?? ""
			CardLabel(text: "Problem\(kind)\(problem.mode.map { " · \($0)" } ?? "")", systemImage: "puzzlepiece")
			Spacer()
			QuietButton(title: "Discard") { Task { await model.discardProblem(problem.toolCallId) } }
			DockChevron(expanded: $showStatement).padding(.trailing, -10)
		}
	}

	/// Expanded: the whole statement, scrolling past 220. Collapsed: its first
	/// line as plain text, formulas as "…".
	@ViewBuilder private var statement: some View {
		if showStatement {
			ScrollView {
				MarkdownView(problem.statement ?? "").frame(maxWidth: .infinity, alignment: .leading)
					.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { statementHeight = $0 }
			}
			.frame(maxHeight: min(220, statementHeight ?? 220))
		} else {
			Text(MarkdownPreview.oneLine(problem.statement ?? ""))
				.font(LHFont.prose(.body))
				.foregroundStyle(LHColor.muted)
				.lineLimit(1)
				.truncationMode(.tail)
				.frame(maxWidth: .infinity, alignment: .leading)
		}
	}

	/// A plugin's problem: its submission editor is plugin code, so it is
	/// answered in the web app; here it can only be discarded.
	private func pluginControls(_ plugin: NativePluginInfo) -> some View {
		VStack(alignment: .leading, spacing: 10) {
			Text("Answer this problem in the web app.").font(LHFont.prose(.callout)).foregroundStyle(LHColor.muted)
			HStack(spacing: 8) {
				if model.isRunning { StopButton { Task { await model.stopTurn() } } }
				OpenInBrowserButton(url: model.webURL)
			}
		}
	}

	private var builtinControls: some View {
		VStack(alignment: .leading, spacing: 10) {
			AnswerField(placeholder: "Your thinking or answer…", text: thinking, lines: 4...8)
			HStack(spacing: 8) {
				if model.isRunning { StopButton { Task { await model.stopTurn() } } }
				Button("Submit") {
					Task {
						await app.dictation?.finish()
						let text = thinking.wrappedValue
						guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
						thinking.wrappedValue = ""
						await model.submitThinking(problemCallId: problem.toolCallId, text: text)
					}
				}
				.buttonStyle(PrimaryButtonStyle())
				.disabled(thinking.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.canAct)
			}
		}
	}
}

// MARK: - Plugin question dock

/// A plugin's question: its answer editor is plugin code, so it is answered
/// in the web app; here it shows its text and can be dismissed. An
/// unavailable one (unreadable on the server) can only be dismissed, as on
/// the web.
struct PluginQuestionDockView: View {
	let model: SessionModel
	let dock: NativePluginQuestionDock
	/// The question's height: its scroll view grows no taller.
	@State private var questionHeight: CGFloat?

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			if dock.available {
				CardLabel(text: dock.label ?? "Question", systemImage: "puzzlepiece")
				ScrollView {
					MarkdownView(dock.question ?? "").fontWeight(.medium).frame(maxWidth: .infinity, alignment: .leading)
						.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { questionHeight = $0 }
				}
				.frame(maxHeight: min(220, questionHeight ?? 220))
				Text("Answer this question in the web app.").font(LHFont.prose(.callout)).foregroundStyle(LHColor.muted)
			} else {
				Text("Question unavailable").font(LHFont.prose(.callout)).foregroundStyle(LHColor.muted)
			}
			HStack(spacing: 8) {
				QuietButton(title: "Dismiss Question") { Task { await model.dismissPluginQuestion(dock) } }
				Spacer()
				if dock.available { OpenInBrowserButton(url: model.webURL).fixedSize() }
			}
		}
		.padding(14)
	}
}

/// Opens this session in the server's web app (Safari), where a plugin's
/// question or problem can be answered.
struct OpenInBrowserButton: View {
	let url: URL
	@Environment(\.openURL) private var openURL

	var body: some View {
		Button { openURL(url) } label: { Label("Open in Browser", systemImage: "arrow.up.right.square").padding(.horizontal, 16) }
			.buttonStyle(PrimaryButtonStyle())
	}
}

extension Array {
	subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
