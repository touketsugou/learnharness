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
						// Applies its own ceiling, which never hides its peek.
						QuestionDockView(model: model, dock: dock, visibleHeight: visibleHeight, share: $questionShare).id(dock.key)
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
		.swipeDownDismissesKeyboard()
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

	/// The dock's height ceiling: its share of the height, but never below
	/// its least height (a share saved without the keyboard would otherwise
	/// squeeze the question away above it), nor above the whole height.
	static func ceiling(share: Double, minHeight: CGFloat, visibleHeight: CGFloat?) -> CGFloat? {
		visibleHeight.map { min(max($0 * CGFloat(share), minHeight), $0) }
	}

	/// Whether the dock, now `height` tall, takes a finger step of `dy`
	/// (down positive) rather than its content: up while it can grow, down
	/// while it can shrink and the content is at its top (`atTop`).
	static func consumes(dy: CGFloat, height: CGFloat, minHeight: CGFloat, maxHeight: CGFloat, atTop: Bool) -> Bool {
		if dy < 0 { return height < maxHeight - 0.5 }
		if dy > 0 { return atTop && height > minHeight + 0.5 }
		return false
	}
}

/// The question dock's hold at 90%: there, a swipe down pulls against it,
/// the dock giving a third of the finger's travel, until 60 pt frees it.
enum QuestionDockHold {
	/// How far the finger pulls down before the hold lets go.
	static let release: CGFloat = 60
	/// The share of the pull the dock follows while held.
	static let give: CGFloat = 1.0 / 3

	/// Whether a dock `height` tall is held: it is at the top (90%), and its
	/// content fills it there (`fitHeight`, the most it shows) rather than
	/// the dock stopping short of it.
	static func holds(height: CGFloat, fitHeight: CGFloat, top: CGFloat) -> Bool {
		fitHeight >= top - 0.5 && height >= top - 0.5
	}

	/// The pull after a finger step `dy` (down positive), never below 0;
	/// nil once it reaches `release`, which frees the dock.
	static func pull(_ pull: CGFloat, step dy: CGFloat) -> CGFloat? {
		let next = max(pull + dy, 0)
		return next >= release ? nil : next
	}

	/// How far below the top a held dock shows under `pull`.
	static func sag(_ pull: CGFloat) -> CGFloat { pull * give }
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
	/// The dock's height when the current drag began, and how far the dock
	/// has moved since (down positive), kept within its limits.
	@State private var dragBase: CGFloat?
	@State private var dragMoved: CGFloat = 0
	/// The handle's last translation, to step it like a swipe.
	@State private var handleTranslation: CGFloat = 0
	@State private var resized = 0
	/// How far this swipe pulls against the hold at 90% (QuestionDockHold);
	/// nil while the dock is free.
	@State private var holdPull: CGFloat?
	/// The hold caught, and let go: each ticks a haptic.
	@State private var held = 0
	@State private var released = 0
	/// Until then, the dock springs to the finger after the hold let go.
	@State private var catchUpUntil: Date?
	/// This swipe started down with the keyboard up: it only closes the
	/// keyboard (swipeDownDismissesKeyboard), so the dock holds still. Nil
	/// until the swipe's first step.
	@State private var heldForKeyboard: Bool?
	/// Swipes on the content resize the dock first (DockScrollResize).
	@State private var scrollLink = DockScrollLink()

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
				.gesture(handleDrag)
				ScrollView {
					form.padding(.horizontal, 14).padding(.bottom, 10)
						.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { formHeight = $0 }
						.background(
							ScrollViewFinder(
								link: scrollLink,
								begin: beginResize,
								resize: { dy, atTop in holdsForKeyboard(dy) || resize(by: dy, atTop: atTop, fitContent: true) },
								end: endResize
							)
						)
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
		.sensoryFeedback(.impact(weight: .medium), trigger: held)
		.sensoryFeedback(.impact(weight: .medium), trigger: released)
		.modifier(DockHeight(maxHeight: QuestionDockSize.ceiling(share: share, minHeight: minHeight, visibleHeight: visibleHeight)))
	}

	/// The least height: the header, a peek of the question, the pinned controls.
	private var minHeight: CGFloat {
		dockHeight - scrollHeight + min(QuestionDockSize.peek, formHeight ?? QuestionDockSize.peek)
	}

	/// The most a swipe on the content grows the dock: until all of it shows,
	/// at most 90%.
	private var fitHeight: CGFloat {
		let fit = dockHeight - scrollHeight + (formHeight ?? scrollHeight)
		return visibleHeight.map { min(fit, $0 * QuestionDockSize.maxShare) } ?? fit
	}

	/// The top: 90% of the height.
	private var topHeight: CGFloat? { visibleHeight.map { $0 * QuestionDockSize.maxShare } }

	/// A resize starts from the height as drawn (a short question sits below
	/// its ceiling), held if that is the top.
	private func beginResize() {
		dragBase = dockHeight
		dragMoved = 0
		heldForKeyboard = nil
		catchUpUntil = nil
		holdPull = topHeight.flatMap { QuestionDockHold.holds(height: dockHeight, fitHeight: fitHeight, top: $0) ? 0 : nil }
	}

	/// Whether the dock holds still for this swipe step: the swipe's first
	/// step decides, down with the keyboard up holding the whole swipe.
	private func holdsForKeyboard(_ dy: CGFloat) -> Bool {
		if heldForKeyboard == nil, dy != 0 { heldForKeyboard = dy > 0 && KeyboardState.shared.isVisible }
		return heldForKeyboard == true
	}

	/// Moves the dock's top edge by `dy` if the dock takes the step. The
	/// handle may raise the ceiling past the content (`fitContent` false); a
	/// swipe on the content grows the dock only until the content fits.
	private func resize(by dy: CGFloat, atTop: Bool, fitContent: Bool) -> Bool {
		guard let top = topHeight, dy != 0 else { return false }
		let base = dragBase ?? dockHeight
		let floor = min(minHeight, top)
		if let pull = holdPull {
			// Held: a pull down from the content's top stretches the dock a
			// little, and back up undoes it; past the release it lets go and
			// springs to the finger.
			guard dy > 0 ? atTop : pull > 0 else { return false }
			if let next = QuestionDockHold.pull(pull, step: dy) {
				holdPull = next
				show(max(top - QuestionDockHold.sag(next), floor), base: base)
			} else {
				holdPull = nil
				released += 1
				catchUpUntil = Date.now.addingTimeInterval(Self.catchUp)
				withAnimation(Self.catchUpSpring) { show(max(top - (pull + dy), floor), base: base) }
			}
			return true
		}
		let maxHeight = fitContent ? fitHeight : top
		let height = base - dragMoved
		guard QuestionDockSize.consumes(dy: dy, height: height, minHeight: minHeight, maxHeight: maxHeight, atTop: atTop) else { return false }
		let next = min(max(height - dy, min(minHeight, maxHeight)), maxHeight)
		if let until = catchUpUntil, Date.now < until {
			withAnimation(Self.catchUpSpring) { show(next, base: base) }
		} else {
			show(next, base: base)
		}
		if QuestionDockHold.holds(height: next, fitHeight: fitHeight, top: top) {
			holdPull = 0
			held += 1
		}
		return true
	}

	/// How long, and how, the dock springs to the finger once the hold lets go.
	private static let catchUp: TimeInterval = 0.2
	private static let catchUpSpring = Animation.spring(duration: catchUp, bounce: 0.15)

	/// Draws the dock `height` tall: its share, from the drag's `base`.
	private func show(_ height: CGFloat, base: CGFloat) {
		dragMoved = base - height
		share = QuestionDockSize.share(share, base: base, drag: dragMoved, minHeight: minHeight, visibleHeight: visibleHeight)
	}

	/// A swipe let go while pulling against the hold springs the dock back to
	/// the top, with no resize haptic: it stays where it was.
	private func endResize(_ didResize: Bool) {
		if let pull = holdPull, pull > 0, let visibleHeight {
			withAnimation(.spring(duration: 0.3, bounce: 0.2)) {
				share = QuestionDockSize.share(share, base: visibleHeight * QuestionDockSize.maxShare, drag: 0, minHeight: minHeight, visibleHeight: visibleHeight)
			}
		} else if didResize && heldForKeyboard != true {
			resized += 1
		}
		dragBase = nil
		dragMoved = 0
		holdPull = nil
		catchUpUntil = nil
		heldForKeyboard = nil
	}

	/// The handle and header drag the top edge. Global, as the dock moves
	/// under the finger.
	private var handleDrag: some Gesture {
		DragGesture(minimumDistance: 4, coordinateSpace: .global)
			.onChanged { value in
				if dragBase == nil {
					beginResize()
					handleTranslation = 0
				}
				let dy = value.translation.height - handleTranslation
				handleTranslation = value.translation.height
				if !holdsForKeyboard(dy) { _ = resize(by: dy, atTop: true, fitContent: false) }
			}
			.onEnded { _ in endResize(true) }
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
